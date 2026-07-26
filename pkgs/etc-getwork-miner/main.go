// etc-getwork-miner — a CPU etchash miner that drives a node over the historical getwork
// protocol (eth_getWork / eth_submitWork). Built to exercise that RPC path against every ETC
// client, not to compete for hashrate: correctness matters, throughput does not.
package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"math/big"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	etchash "github.com/etclabscore/go-etchash"
	"github.com/ethereum/go-ethereum/common"
)

var maxUint256 = new(big.Int).Exp(big.NewInt(2), big.NewInt(256), nil)

// lightSearch mines with the etchash light cache (~50 MB) instead of the full DAG (~3 GB),
// so it fits alongside other services on a memory-constrained box. It recomputes each dataset
// item on demand via Light.Compute, so it is much slower per hash than Full.Search — fine for
// mordor's low difficulty, where correctness matters more than throughput. The node re-verifies
// every submitted solution, so a nonce found here is only accepted if it is genuinely valid.
func lightSearch(hasher *etchash.Etchash, w *work, stop <-chan struct{}, index int) (uint64, []byte) {
	target := new(big.Int).Div(maxUint256, w.difficulty)
	r := rand.New(rand.NewSource(time.Now().UnixNano() + int64(index)))
	nonce := uint64(r.Int63())
	result := new(big.Int)
	for {
		select {
		case <-stop:
			return 0, nil
		default:
		}
		mixDigest, hash := hasher.Light.Compute(w.number, w.powHash, nonce)
		if result.SetBytes(hash.Bytes()).Cmp(target) <= 0 {
			return nonce, mixDigest.Bytes()
		}
		nonce++
	}
}

type work struct {
	powHash    common.Hash
	seedHash   common.Hash
	number     uint64
	difficulty *big.Int
}

func (w *work) Difficulty() *big.Int     { return w.difficulty }
func (w *work) HashNoNonce() common.Hash { return w.powHash }
func (w *work) NumberU64() uint64        { return w.number }
func (w *work) Nonce() uint64            { return 0 }
func (w *work) MixDigest() common.Hash   { return common.Hash{} }

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string { return fmt.Sprintf("rpc error %d: %s", e.Code, e.Message) }

type rpcClient struct {
	url  string
	http *http.Client
}

func (c *rpcClient) call(method string, params []any, out any) error {
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": method, "params": params,
	})
	if err != nil {
		return err
	}
	resp, err := c.http.Post(c.url, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  *rpcError       `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return err
	}
	if envelope.Error != nil {
		return envelope.Error
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(envelope.Result, out)
}

func parseUint64(s string) (uint64, error) {
	return strconv.ParseUint(strings.TrimPrefix(s, "0x"), 16, 64)
}

// getWork returns [powHash, seedHash, target, blockNumber]. The block number is required:
// under ECIP-1099 the epoch cannot be recovered from the seed hash alone, so a node that
// omits it (pre-4-tuple getwork) cannot be mined against correctly.
func (c *rpcClient) getWork() (*work, error) {
	var res []string
	if err := c.call("eth_getWork", []any{}, &res); err != nil {
		return nil, err
	}
	if len(res) < 4 {
		return nil, fmt.Errorf("eth_getWork returned %d fields, need 4 (missing block number)", len(res))
	}
	number, err := parseUint64(res[3])
	if err != nil {
		return nil, fmt.Errorf("block number %q: %w", res[3], err)
	}
	target := new(big.Int).SetBytes(common.HexToHash(res[2]).Bytes())
	if target.Sign() == 0 {
		return nil, errors.New("eth_getWork returned zero target")
	}
	// The node sends target = 2^256/difficulty, so recovering difficulty rounds up rather
	// than down. That makes our search strictly no more lenient than the node's own check,
	// so a solution we accept is never one the node would reject.
	return &work{
		powHash:    common.HexToHash(res[0]),
		seedHash:   common.HexToHash(res[1]),
		number:     number,
		difficulty: new(big.Int).Div(maxUint256, target),
	}, nil
}

func (c *rpcClient) submitWork(nonce uint64, powHash common.Hash, mixDigest []byte) (bool, error) {
	var nonceBytes [8]byte
	for i := 0; i < 8; i++ {
		nonceBytes[7-i] = byte(nonce >> (8 * i))
	}
	var accepted bool
	err := c.call("eth_submitWork", []any{
		"0x" + hex.EncodeToString(nonceBytes[:]),
		powHash.Hex(),
		"0x" + hex.EncodeToString(mixDigest),
	}, &accepted)
	return accepted, err
}

// submitHashrate reports our measured hash rate to the node via eth_submitHashrate — the third
// leg of the getwork protocol (getWork/submitWork/submitHashrate), exercised here on every ETC
// client. The node folds it into eth_hashrate; id is a stable per-process client tag so repeat
// reports update the same slot. hashrate is a plain hex QUANTITY, id a 32-byte hex string.
func (c *rpcClient) submitHashrate(hashrate int64, id common.Hash) (bool, error) {
	var ok bool
	err := c.call("eth_submitHashrate", []any{
		fmt.Sprintf("0x%x", hashrate),
		id.Hex(),
	}, &ok)
	return ok, err
}

func main() {
	var (
		rpcURL   = flag.String("rpc", "http://127.0.0.1:8545", "node JSON-RPC endpoint")
		threads  = flag.Int("threads", 0, "search threads (0 = all cores)")
		interval = flag.Duration("interval", 2*time.Second, "eth_getWork poll interval")
		ecip1099 = flag.Uint64("ecip1099-block", 2520000, "ECIP-1099 activation block (mordor 2520000, classic 11700000)")
		light    = flag.Bool("light", false, "search with the etchash light cache (~50MB) instead of the full DAG (~3GB); slower per hash, for memory-constrained shared boxes")

		hashrateAddr   = flag.String("hashrate-addr", "", "if set, serve the current hash rate as JSON at http://<addr>/ (for the ethstats hashrate proxy)")
		submitHashrate = flag.Bool("submit-hashrate", false, "periodically report the hash rate to the node via eth_submitHashrate")
	)
	flag.Parse()

	if *threads <= 0 {
		*threads = runtime.NumCPU()
	}
	client := &rpcClient{url: *rpcURL, http: &http.Client{Timeout: 10 * time.Second}}
	hasher := etchash.New(ecip1099, nil)

	log.Printf("etc-getwork-miner: rpc=%s threads=%d ecip1099-block=%d light=%t", *rpcURL, *threads, *ecip1099, *light)

	// Hash-rate reporting. Full.Search maintains go-etchash's internal rate meter, so
	// hasher.GetHashrate() is a real measured H/s summed across all search threads; in -light
	// mode there is no meter (we drive Light.Compute ourselves), so it reads 0.
	if *hashrateAddr != "" {
		mux := http.NewServeMux()
		mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, "{\"hashrate\":%d}\n", hasher.GetHashrate())
		})
		srv := &http.Server{Addr: *hashrateAddr, Handler: mux}
		go func() {
			if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Printf("hashrate http server: %v", err)
			}
		}()
		log.Printf("serving hash rate at http://%s/", *hashrateAddr)
	}
	if *submitHashrate {
		var idb [32]byte
		idr := rand.New(rand.NewSource(time.Now().UnixNano()))
		for i := range idb {
			idb[i] = byte(idr.Intn(256))
		}
		id := common.BytesToHash(idb[:])
		go func() {
			t := time.NewTicker(5 * time.Second)
			defer t.Stop()
			for range t.C {
				if _, err := client.submitHashrate(hasher.GetHashrate(), id); err != nil {
					log.Printf("eth_submitHashrate: %v", err)
				}
			}
		}()
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)

	var (
		current *work
		stop    chan struct{}
		wg      sync.WaitGroup
	)
	halt := func() {
		if stop != nil {
			close(stop)
			wg.Wait()
			stop = nil
		}
	}
	defer halt()

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()

	for {
		select {
		case <-sigs:
			log.Print("shutting down")
			halt()
			return
		case <-ticker.C:
		}

		w, err := client.getWork()
		if err != nil {
			// "no work available" is the normal idle state when the node is not building
			// templates, so this stays a warning rather than a fatal.
			log.Printf("eth_getWork: %v", err)
			continue
		}
		if current != nil && current.powHash == w.powHash {
			continue
		}

		halt()
		current = w
		stop = make(chan struct{})
		log.Printf("new work: block=%d powHash=%s difficulty=%s", w.number, w.powHash.Hex(), w.difficulty)

		for i := 0; i < *threads; i++ {
			wg.Add(1)
			go func(index int, w *work, stop chan struct{}) {
				defer wg.Done()
				var nonce uint64
				var mixDigest []byte
				if *light {
					nonce, mixDigest = lightSearch(hasher, w, stop, index)
				} else {
					nonce, mixDigest = hasher.Search(w, stop, index)
				}
				if mixDigest == nil {
					return
				}
				accepted, err := client.submitWork(nonce, w.powHash, mixDigest)
				if err != nil {
					log.Printf("eth_submitWork block=%d nonce=%d: %v", w.number, nonce, err)
					return
				}
				log.Printf("eth_submitWork block=%d nonce=%d accepted=%t", w.number, nonce, accepted)
			}(i, w, stop)
		}
	}
}
