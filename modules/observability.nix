# node_exporter (from inventory/group_vars/all/node_exporter.yml): :9100, systemd
# collector enabled. It's a read-only GET of system metrics.
_: {
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    listenAddress = "0.0.0.0";
    enabledCollectors = [ "systemd" ];
    extraFlags = [ "--collector.systemd.enable-restarts-metrics" ]; # node_systemd_service_restart_total
  };
  networking.firewall.allowedTCPPorts = [ 9100 ];
}
