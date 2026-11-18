test_container_devices_proxy() {
  ensure_import_testimage

  HOST_TCP_PORT="$(local_tcp_port)"
  HOST_TCP_PORT2="$(local_tcp_port)"
  HOST_TCP_PORT3="$(local_tcp_port)"

  container_devices_proxy_validation
  container_devices_proxy_tcp
  container_devices_proxy_tcp_unix
  container_devices_proxy_tcp_udp
  container_devices_proxy_udp
  container_devices_proxy_unix
  container_devices_proxy_unix_udp
  container_devices_proxy_unix_tcp
  container_devices_proxy_with_overlapping_forward_net

  unset HOST_TCP_PORT HOST_TCP_PORT2 HOST_TCP_PORT3
}

test_vm_devices_proxy() {
  HOST_TCP_PORT="$(local_tcp_port)"
  HOST_TCP_PORT2="$(local_tcp_port)"

  container_devices_proxy_vm

  unset HOST_TCP_PORT HOST_TCP_PORT2
}

container_devices_proxy_validation() {
  echo "====> Testing proxy validation"

  # Setup
  lxc launch testimage proxyTester

  # Check that connecting to a DNS name is not allowed (security risk).
  if lxc config device add proxyTester proxyDev proxy "listen=tcp:127.0.0.1:$HOST_TCP_PORT" connect=tcp:localhost:4321 bind=host ; then
    echo "Proxy device shouldn't allow connect hostnames, only IPs"
    false
  fi

  # Check that unequal multi-port mappings are rejected.
  if VALIDATION_ERROR=$(lxc config device add proxyTester proxyDev proxy "listen=tcp:127.0.0.1:${HOST_TCP_PORT},${HOST_TCP_PORT2},${HOST_TCP_PORT3}" "connect=tcp:127.0.0.1:4321,4322" bind=host 2>&1); then
    echo "Proxy device shouldn't allow unequal multi-port mappings"
    false
  fi
  [[ "${VALIDATION_ERROR}" == *"Mismatch between listen port(s) and connect port(s) count"* ]]

  # Check that UDP listeners cannot connect to stream sockets.
  if VALIDATION_ERROR=$(lxc config device add proxyTester proxyDev proxy "listen=udp:127.0.0.1:${HOST_TCP_PORT}" "connect=tcp:127.0.0.1:4321" bind=host 2>&1); then
    echo "Proxy device shouldn't proxy UDP listeners to non-UDP targets"
    false
  fi
  [[ "${VALIDATION_ERROR}" == *"Proxying from UDP to non-UDP protocols is not supported"* ]]

  # Check using wildcard addresses isn't allowed in NAT mode.
  if lxc config device add proxyTester proxyDev proxy "listen=tcp:0.0.0.0:$HOST_TCP_PORT" connect=tcp:0.0.0.0:4321 nat=true ; then
    echo "Proxy device shouldn't allow wildcard IPv4 listen addresses in NAT mode"
    false
  fi
  if lxc config device add proxyTester proxyDev proxy "listen=tcp:[::]:$HOST_TCP_PORT" connect=tcp:0.0.0.0:4321 nat=true ; then
    echo "Proxy device shouldn't allow wildcard IPv6 listen addresses in NAT mode"
    false
  fi

  # Check using mixing IP versions in listen/connect addresses isn't allowed in NAT mode.
  if lxc config device add proxyTester proxyDev proxy "listen=tcp:127.0.0.1:$HOST_TCP_PORT" "connect=tcp:[::]:4321" nat=true ; then
    echo "Proxy device shouldn't allow mixing IP address versions in NAT mode"
    false
  fi
  if lxc config device add proxyTester proxyDev proxy "listen=tcp:[::1]:$HOST_TCP_PORT" connect=tcp:0.0.0.0:4321 nat=true ; then
    echo "Proxy device shouldn't allow mixing IP address versions in NAT mode"
    false
  fi

  # Check user proxy_protocol isn't allowed in NAT mode.
  if lxc config device add proxyTester proxyDev proxy "listen=tcp:[::1]:$HOST_TCP_PORT" "connect=tcp:[::]:4321" nat=true proxy_protocol=true ; then
    echo "Proxy device shouldn't allow proxy_protocol in NAT mode"
    false
  fi

  # Check that old invalid config doesn't prevent device being stopped and removed cleanly.
  lxc config device add proxyTester proxyDev proxy "listen=tcp:127.0.0.1:$HOST_TCP_PORT" connect=tcp:127.0.0.1:4321 bind=host
  lxd sql global "UPDATE instances_devices_config SET value='tcp:localhost:4321' WHERE value='tcp:127.0.0.1:4321';"
  lxc config device remove proxyTester proxyDev

  # Add the device again with the same listen param so if the old process hasn't been stopped it will fail to start.
  lxc config device add proxyTester proxyDev proxy "listen=tcp:127.0.0.1:$HOST_TCP_PORT" connect=tcp:127.0.0.1:4321 bind=host

  lxc delete -f proxyTester
}

container_devices_proxy_tcp() {
  echo "====> Testing tcp proxying"

  # Setup
  MESSAGE="Proxy device test string: tcp"
  lxc launch testimage proxyTester

  # Initial test
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat tcp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device add proxyTester proxyDev proxy "listen=tcp:127.0.0.1:$HOST_TCP_PORT" connect=tcp:127.0.0.1:4321 bind=host
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  # Restart the container
  lxc restart -f proxyTester
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat tcp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart on container restart"
    false
  fi

  # Change the port
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat tcp4-listen:1337 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device set proxyTester proxyDev connect tcp:127.0.0.1:1337
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart when config was updated"
    false
  fi

  # Initial test: Setting up multiple TCP port proxies
  lxc config device remove proxyTester proxyDev
  PID=$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)

  # Set up three socat listeners in the container
  nsenter -n -U -t "${PID}" -- socat tcp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  nsenter -n -U -t "${PID}" -- socat tcp4-listen:4322 exec:/bin/cat &
  NSENTER_PID1=$!
  nsenter -n -U -t "${PID}" -- socat tcp4-listen:4323 exec:/bin/cat &
  NSENTER_PID2=$!

  # Create a proxy device that maps three host ports to three container ports
  lxc config device add proxyTester proxyDev proxy "listen=tcp:127.0.0.1:$HOST_TCP_PORT,$HOST_TCP_PORT2,$HOST_TCP_PORT3" connect=tcp:127.0.0.1:4321-4323 bind=host
  sleep 0.2

  echo "Testing standard TCP connection through proxy"
  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true
  echo "Testing standard TCP connection through proxy with different port"
  ECHO1=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT2}",shut-down)
  kill "${NSENTER_PID1}" 2>/dev/null || true
  wait "${NSENTER_PID1}" 2>/dev/null || true
  echo "Testing half-closed TCP connection through proxy"
  ECHO2=$( echo "${MESSAGE}" | nc -N 127.0.0.1 "${HOST_TCP_PORT3}") # the -N flag to netcat closes the socket after EOF on input
  kill "${NSENTER_PID2}" 2>/dev/null || true
  wait "${NSENTER_PID2}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  if [ "${ECHO1}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  if [ "${ECHO2}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  # Cleanup
  lxc delete -f proxyTester

  # Try NAT
  lxc init testimage nattest

  lxc network create lxdt$$ dns.domain=test dns.mode=managed ipv6.dhcp.stateful=true ipv4.address=192.0.2.1/24 ipv6.address=2001:db8::1/64
  lxc network attach lxdt$$ nattest eth0
  v4_addr="192.0.2.10"
  v6_addr="2001:db8::100"
  lxc config device set nattest eth0 ipv4.address="${v4_addr}" ipv6.address="${v6_addr}"

  firewallDriver=$(lxc info | awk -F ":" '/firewall:/{gsub(/ /, "", $0); print $2}')

  lxc start nattest
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(iptables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "0" ]
  else
    ! nft -nn list chain inet lxd prert.nattest.validNAT || false
    ! nft -nn list chain inet lxd out.nattest.validNAT || false
  fi

  lxc config device add nattest validNAT proxy listen="tcp:127.0.0.1:1234" connect="tcp:${v4_addr}:1234" bind=host
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(iptables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "0" ]
  else
    ! nft -nn list chain inet lxd prert.nattest.validNAT || false
    ! nft -nn list chain inet lxd out.nattest.validNAT || false
  fi

  # enable NAT
  lxc config device set nattest validNAT nat true
  if [ "$firewallDriver" = "xtables" ]; then
    iptables -w -t nat -S | grep -F -- "-A PREROUTING -d 127.0.0.1/32 -p tcp -m tcp --dport 1234 -m comment --comment \"generated for LXD container nattest (validNAT)\" -j DNAT --to-destination ${v4_addr}:1234"
    iptables -w -t nat -S | grep -F -- "-A OUTPUT -d 127.0.0.1/32 -p tcp -m tcp --dport 1234 -m comment --comment \"generated for LXD container nattest (validNAT)\" -j DNAT --to-destination ${v4_addr}:1234"
    iptables -w -t nat -S | grep -F -- "-A POSTROUTING -s ${v4_addr}/32 -d ${v4_addr}/32 -p tcp -m tcp --dport 1234 -m comment --comment \"generated for LXD container nattest (validNAT)\" -j MASQUERADE"
  else
    [ "$(nft -nn list chain inet lxd prert.nattest.validNAT | grep -cF "ip daddr 127.0.0.1 tcp dport 1234 dnat ip to ${v4_addr}:1234")" = "1" ]
    [ "$(nft -nn list chain inet lxd out.nattest.validNAT | grep -cF "ip daddr 127.0.0.1 tcp dport 1234 dnat ip to ${v4_addr}:1234")" = "1" ]
  fi

  lxc config device remove nattest validNAT
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(iptables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "0" ]
  else
    ! nft -nn list chain inet lxd prert.nattest.validNAT || false
    ! nft -nn list chain inet lxd out.nattest.validNAT || false
  fi

  lxc config device add nattest validNAT proxy listen="tcp:127.0.0.1:1234-1235" connect="tcp:${v4_addr}:1234" bind=host nat=true
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(iptables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "3" ]
  else
    [ "$(nft -nn list chain inet lxd prert.nattest.validNAT | grep -cF "ip daddr 127.0.0.1 tcp dport 1234-1235 dnat ip to ${v4_addr}:1234")" = "1" ]
    [ "$(nft -nn list chain inet lxd out.nattest.validNAT | grep -cF "ip daddr 127.0.0.1 tcp dport 1234-1235 dnat ip to ${v4_addr}:1234")" = "1" ]
  fi

  lxc config device remove nattest validNAT
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(iptables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "0" ]
  else
    ! nft -nn list chain inet lxd prert.nattest.validNAT || false
    ! nft -nn list chain inet lxd out.nattest.validNAT || false
  fi

  lxc config device add nattest validNAT proxy listen="tcp:127.0.0.1:1234-1235" connect="tcp:${v4_addr}:1234-1235" bind=host nat=true
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(iptables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "3" ]
  else
    [ "$(nft -nn list chain inet lxd prert.nattest.validNAT | grep -cF "ip daddr 127.0.0.1 tcp dport 1234-1235 dnat ip to ${v4_addr}")" = "1" ]
    [ "$(nft -nn list chain inet lxd out.nattest.validNAT | grep -cF "ip daddr 127.0.0.1 tcp dport 1234-1235 dnat ip to ${v4_addr}")" = "1" ]
  fi

  lxc config device remove nattest validNAT
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(iptables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "0" ]
  else
    ! nft -nn list chain inet lxd prert.nattest.validNAT || false
    ! nft -nn list chain inet lxd out.nattest.validNAT || false
  fi

  # IPv6 test
  lxc config device add nattest validNAT proxy listen="tcp:[::1]:1234" connect="tcp:[::]:1234" bind=host nat=true
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(ip6tables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "3" ]
  else
    [ "$(nft -nn list chain inet lxd prert.nattest.validNAT | grep -cF "ip6 daddr ::1 tcp dport 1234 dnat ip6 to [${v6_addr}]:1234")" = "1" ]
    [ "$(nft -nn list chain inet lxd out.nattest.validNAT | grep -cF "ip6 daddr ::1 tcp dport 1234 dnat ip6 to [${v6_addr}]:1234")" = "1" ]
  fi

  lxc config device unset nattest validNAT nat
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(ip6tables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "0" ]
  else
    ! nft -nn list chain inet lxd prert.nattest.validNAT || false
    ! nft -nn list chain inet lxd out.nattest.validNAT || false
  fi

  lxc config device remove nattest validNAT

  # This won't enable NAT
  lxc config device add nattest invalidNAT proxy listen="tcp:127.0.0.1:1234" connect="udp:${v4_addr}:1234" bind=host
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(iptables -w -t nat -S | grep -cF "generated for LXD container nattest (invalidNAT)")" = "0" ]
  else
    ! nft -nn list chain inet lxd prert.nattest.invalidNAT || false
    ! nft -nn list chain inet lxd out.nattest.invalidNAT || false
  fi

  lxc delete -f nattest
  if [ "$firewallDriver" = "xtables" ]; then
    [ "$(iptables -w -t nat -S | grep -cF "generated for LXD container nattest (validNAT)")" = "0" ]
  else
    ! nft -nn list chain inet lxd prert.nattest.validNAT || false
    ! nft -nn list chain inet lxd out.nattest.validNAT || false
  fi

  lxc network delete lxdt$$
}

container_devices_proxy_unix() {
  echo "====> Testing unix proxying"

  # Setup
  MESSAGE="Proxy device test string: unix"
  HOST_SOCK="${TEST_DIR}/lxdtest-$(basename "${LXD_DIR}")-host.sock"
  lxc launch testimage proxyTester

  # Some busybox images don't have /tmp globally accessible.
  lxc exec proxyTester -- chmod 1777 /tmp

  # Initial test
  (
    PID="$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)"
    cd "/proc/${PID}/root/tmp/" || exit
    umask 0000
    exec nsenter -n -U -t "${PID}" -- socat unix-listen:"lxdtest-$(basename "${LXD_DIR}").sock",unlink-early exec:/bin/cat
  ) &
  NSENTER_PID=$!
  sleep 0.2

  lxc config device add proxyTester proxyDev proxy "listen=unix:${HOST_SOCK}" uid=1234 gid=1234 security.uid=1234 security.gid=1234 connect=unix:/tmp/"lxdtest-$(basename "${LXD_DIR}").sock" bind=host

  ECHO=$( (echo "${MESSAGE}" ; sleep 0.1) | socat - unix:"${HOST_SOCK}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  rm -f "${HOST_SOCK}"

  # Restart the container
  lxc restart -f proxyTester
  (
    PID="$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)"
    cd "/proc/${PID}/root/tmp/" || exit
    umask 0000
    exec nsenter -n -U -t "${PID}" -- socat unix-listen:"lxdtest-$(basename "${LXD_DIR}").sock",unlink-early exec:/bin/cat
  ) &
  NSENTER_PID=$!
  sleep 0.2

  ECHO=$( (echo "${MESSAGE}" ; sleep 0.1) | socat - unix:"${HOST_SOCK}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart on container restart"
    false
  fi

  rm -f "${HOST_SOCK}"

  # Change the socket
  (
    PID="$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)"
    cd "/proc/${PID}/root/tmp/" || exit
    umask 0000
    exec nsenter -n -U -t "${PID}" -- socat unix-listen:"lxdtest-$(basename "${LXD_DIR}")-2.sock",unlink-early exec:/bin/cat
  ) &
  NSENTER_PID=$!

  lxc config device set proxyTester proxyDev connect unix:/tmp/"lxdtest-$(basename "${LXD_DIR}")-2.sock"
  sleep 0.2

  ECHO=$( (echo "${MESSAGE}" ; sleep 0.1) | socat - unix:"${HOST_SOCK}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart when config was updated"
    false
  fi

  # Ensure host socket removed upon device removal.
  lxc config device remove proxyTester proxyDev
  if [ -e "${HOST_SOCK}" ]; then
    echo "Host socket was not removed upon device removal"
    false
  fi

  # Cleanup
  lxc delete -f proxyTester
}

container_devices_proxy_tcp_unix() {
  echo "====> Testing tcp to unix proxying"

  # Setup
  MESSAGE="Proxy device test string: tcp -> unix"
  lxc launch testimage proxyTester

  # Initial test
  (
    PID="$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)"
    cd "/proc/${PID}/root/tmp/" || exit
    umask 0000
    exec nsenter -n -U -t "${PID}" -- socat unix-listen:"lxdtest-$(basename "${LXD_DIR}").sock",unlink-early exec:/bin/cat
  ) &
  NSENTER_PID=$!

  lxc config device add proxyTester proxyDev proxy "listen=tcp:127.0.0.1:${HOST_TCP_PORT}" connect=unix:/tmp/"lxdtest-$(basename "${LXD_DIR}").sock" bind=host
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  # Restart the container
  lxc restart -f proxyTester
  (
    PID="$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)"
    cd "/proc/${PID}/root/tmp/" || exit
    umask 0000
    exec nsenter -n -U -t "${PID}" -- socat unix-listen:"lxdtest-$(basename "${LXD_DIR}").sock",unlink-early exec:/bin/cat
  ) &
  NSENTER_PID=$!
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart on container restart"
    false
  fi

  # Change the socket
  (
    PID="$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)"
    cd "/proc/${PID}/root/tmp/" || exit
    umask 0000
    exec nsenter -n -U -t "${PID}" -- socat unix-listen:"lxdtest-$(basename "${LXD_DIR}")-2.sock",unlink-early exec:/bin/cat
  ) &
  NSENTER_PID=$!

  lxc config device set proxyTester proxyDev connect unix:/tmp/"lxdtest-$(basename "${LXD_DIR}")-2.sock"
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart when config was updated"
    false
  fi

  # Verify that EOF is forwarded from a container TCP listener to a host Unix socket.
  lxc config device remove proxyTester proxyDev
  HOST_SOCK="${TEST_DIR}/lxdtest-$(basename "${LXD_DIR}")-host.sock"
  socat unix-listen:"${HOST_SOCK}",unlink-early exec:/bin/cat &
  NSENTER_PID=$!

  lxc config device add proxyTester proxyDev proxy listen=tcp:127.0.0.1:4321 connect=unix:"${HOST_SOCK}" bind=instance
  sleep 0.2

  PID=$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)
  ECHO=$(echo "${MESSAGE}" | nsenter -n -U -t "${PID}" -- socat - tcp4:127.0.0.1:4321,shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not forward TCP EOF to the host Unix socket"
    false
  fi

  # Cleanup
  lxc delete -f proxyTester
}

container_devices_proxy_vm() {
  echo "====> Testing VM non-NAT proxying"

  ensure_import_ubuntu_vm_image
  VM_NAME="proxyVM"
  MESSAGE="Proxy device test string: VM"
  lxc launch ubuntu-vm "${VM_NAME}" --vm -c limits.memory=384MiB -d "${SMALL_VM_ROOT_DISK}"
  waitInstanceReady "${VM_NAME}"

  # Host-bound proxy connecting to a TCP listener in the VM.
  VM_PORT=4321
  lxc exec "${VM_NAME}" -- python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', ${VM_PORT})); s.listen(); c,_=s.accept(); data=b''.join(iter(lambda: c.recv(4096), b'')); c.sendall(data)" &
  VM_SERVER_PID=$!
  lxc config device add "${VM_NAME}" proxyDev proxy listen=tcp:127.0.0.1:"${HOST_TCP_PORT}" connect=tcp:127.0.0.1:"${VM_PORT}" bind=host nat=false
  sleep 0.2

  ECHO=$(echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${VM_SERVER_PID}" 2>/dev/null || true
  wait "${VM_SERVER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/${VM_NAME}/proxy.proxyDev.log"
    echo "VM proxy did not properly send data from the host to the VM"
    false
  fi

  # Instance-bound proxy connecting back to a TCP listener on the host.
  lxc config device remove "${VM_NAME}" proxyDev
  socat tcp4-listen:"${HOST_TCP_PORT2}" exec:/bin/cat &
  HOST_SERVER_PID=$!
  lxc config device add "${VM_NAME}" proxyDev proxy listen=tcp:127.0.0.1:4322 connect=tcp:127.0.0.1:"${HOST_TCP_PORT2}" bind=instance nat=false
  sleep 0.2

  ECHO=$(lxc exec "${VM_NAME}" -- python3 -c "import socket,sys; s=socket.create_connection(('127.0.0.1', 4322)); s.sendall(b'${MESSAGE}'); s.shutdown(socket.SHUT_WR); sys.stdout.buffer.write(s.recv(4096))")
  kill "${HOST_SERVER_PID}" 2>/dev/null || true
  wait "${HOST_SERVER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/${VM_NAME}/proxy.proxyDev.log"
    echo "VM proxy did not properly send data from the VM to the host"
    false
  fi

  # Host-bound Unix socket proxy connecting to a Unix listener in the VM.
  lxc config device remove "${VM_NAME}" proxyDev
  HOST_SOCK="${TEST_DIR}/lxdtest-$(basename "${LXD_DIR}")-vm-host.sock"
  VM_SOCK="/tmp/lxd-proxy-vm.sock"
  lxc exec "${VM_NAME}" -- python3 -c "import os,socket; p='${VM_SOCK}'; os.unlink(p) if os.path.exists(p) else None; s=socket.socket(socket.AF_UNIX); s.bind(p); s.listen(); c,_=s.accept(); data=b''.join(iter(lambda: c.recv(4096), b'')); c.sendall(data)" &
  VM_SERVER_PID=$!
  lxc config device add "${VM_NAME}" proxyDev proxy listen=unix:"${HOST_SOCK}" connect=unix:"${VM_SOCK}" bind=host nat=false
  sleep 0.2

  ECHO=$(python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect('${HOST_SOCK}'); s.sendall(b'${MESSAGE}'); s.shutdown(socket.SHUT_WR); sys.stdout.buffer.write(b''.join(iter(lambda: s.recv(4096), b'')))")
  kill "${VM_SERVER_PID}" 2>/dev/null || true
  wait "${VM_SERVER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/${VM_NAME}/proxy.proxyDev.log"
    echo "VM proxy did not properly send Unix socket data from the host to the VM"
    false
  fi

  # Instance-bound Unix socket proxy connecting to a Unix listener on the host.
  lxc config device remove "${VM_NAME}" proxyDev
  socat unix-listen:"${HOST_SOCK}",unlink-early exec:/bin/cat &
  HOST_SERVER_PID=$!
  lxc config device add "${VM_NAME}" proxyDev proxy listen=unix:/tmp/lxd-proxy-vm-client.sock connect=unix:"${HOST_SOCK}" bind=instance nat=false
  lxc exec "${VM_NAME}" -- systemctl restart --no-block lxd-agent.service || true
  waitInstanceReady "${VM_NAME}"

  ECHO=$(lxc exec "${VM_NAME}" -- python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect('/tmp/lxd-proxy-vm-client.sock'); s.sendall(b'${MESSAGE}'); s.shutdown(socket.SHUT_WR); sys.stdout.buffer.write(b''.join(iter(lambda: s.recv(4096), b'')))")
  kill "${HOST_SERVER_PID}" 2>/dev/null || true
  wait "${HOST_SERVER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/${VM_NAME}/proxy.proxyDev.log"
    echo "VM proxy did not properly send Unix socket data from the VM to the host"
    false
  fi

  # Host-bound UDP proxy connecting to a listener in the VM.
  lxc config device remove "${VM_NAME}" proxyDev
  VM_PORT=4323
  lxc exec "${VM_NAME}" -- python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('127.0.0.1', ${VM_PORT})); data,client=s.recvfrom(4096); s.sendto(data, client)" &
  VM_SERVER_PID=$!
  lxc config device add "${VM_NAME}" proxyDev proxy listen=udp:127.0.0.1:"${HOST_TCP_PORT}" connect=udp:127.0.0.1:"${VM_PORT}" bind=host nat=false
  sleep 0.2

  ECHO=$(echo "${MESSAGE}" | socat - udp4:127.0.0.1:"${HOST_TCP_PORT}")
  kill "${VM_SERVER_PID}" 2>/dev/null || true
  wait "${VM_SERVER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/${VM_NAME}/proxy.proxyDev.log"
    echo "VM proxy did not properly send UDP data from the host to the VM"
    false
  fi

  # Instance-bound UDP proxy connecting to a listener on the host.
  lxc config device remove "${VM_NAME}" proxyDev
  socat udp4-listen:"${HOST_TCP_PORT2}" exec:/bin/cat &
  HOST_SERVER_PID=$!
  lxc config device add "${VM_NAME}" proxyDev proxy listen=udp:127.0.0.1:4324 connect=udp:127.0.0.1:"${HOST_TCP_PORT2}" bind=instance nat=false
  sleep 0.2

  ECHO=$(lxc exec "${VM_NAME}" -- python3 -c "import socket,sys; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5); s.sendto(b'${MESSAGE}', ('127.0.0.1', 4324)); sys.stdout.buffer.write(s.recv(4096))")
  kill "${HOST_SERVER_PID}" 2>/dev/null || true
  wait "${HOST_SERVER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/${VM_NAME}/proxy.proxyDev.log"
    echo "VM proxy did not properly send UDP data from the VM to the host"
    false
  fi

  lxc delete -f "${VM_NAME}"
  unset VM_NAME VM_PORT MESSAGE
}

container_devices_proxy_unix_tcp() {
  echo "====> Testing unix to tcp proxying"

  # Setup
  MESSAGE="Proxy device test string: unix -> tcp"
  HOST_SOCK="${TEST_DIR}/lxdtest-$(basename "${LXD_DIR}")-host.sock"
  lxc launch testimage proxyTester

  # Initial test
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat tcp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device add proxyTester proxyDev proxy "listen=unix:${HOST_SOCK}" connect=tcp:127.0.0.1:4321 bind=host
  sleep 0.2

  ECHO=$( (echo "${MESSAGE}" ; sleep 0.1) | socat - unix:"${HOST_SOCK}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  rm -f "${HOST_SOCK}"

  # Restart the container
  lxc restart -f proxyTester
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat tcp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  sleep 0.2

  ECHO=$( (echo "${MESSAGE}" ; sleep 0.1) | socat - unix:"${HOST_SOCK}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart on container restart"
    false
  fi

  rm -f "${HOST_SOCK}"

  # Change the port
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat tcp4-listen:1337 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device set proxyTester proxyDev connect tcp:127.0.0.1:1337
  sleep 0.2

  ECHO=$( (echo "${MESSAGE}" ; sleep 0.1) | socat - unix:"${HOST_SOCK}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart when config was updated"
    false
  fi

  rm -f "${HOST_SOCK}"

  # Cleanup
  lxc delete -f proxyTester
}

container_devices_proxy_udp() {
  echo "====> Testing udp proxying"

  # Setup
  MESSAGE="Proxy device test string: udp"
  HOST_UDP_PORT=$(local_tcp_port)
  lxc launch testimage proxyTester

  # Initial test
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat udp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device add proxyTester proxyDev proxy "listen=udp:127.0.0.1:$HOST_UDP_PORT" connect=udp:127.0.0.1:4321 bind=host
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - udp:127.0.0.1:"${HOST_UDP_PORT}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  # Restart the container
  lxc restart -f proxyTester
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat udp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - udp:127.0.0.1:"${HOST_UDP_PORT}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart on container restart"
    false
  fi

  # Change the port
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat udp4-listen:1337 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device set proxyTester proxyDev connect udp:127.0.0.1:1337
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - udp:127.0.0.1:"${HOST_UDP_PORT}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart when config was updated"
    false
  fi

  # Cleanup
  lxc delete -f proxyTester
}

container_devices_proxy_unix_udp() {
  echo "====> Testing unix to udp proxying"

  # Setup
  MESSAGE="Proxy device test string: unix -> udp"
  HOST_SOCK="${TEST_DIR}/lxdtest-$(basename "${LXD_DIR}")-host.sock"
  lxc launch testimage proxyTester

  # Initial test
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat udp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device add proxyTester proxyDev proxy "listen=unix:${HOST_SOCK}" connect=udp:127.0.0.1:4321 bind=host
  sleep 0.2

  ECHO=$( (echo "${MESSAGE}" ; sleep 0.1) | socat - unix:"${HOST_SOCK}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  rm -f "${HOST_SOCK}"

  # Restart the container
  lxc restart -f proxyTester
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat udp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  sleep 0.2

  ECHO=$( (echo "${MESSAGE}" ; sleep 0.1) | socat - unix:"${HOST_SOCK}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart on container restart"
    false
  fi

  rm -f "${HOST_SOCK}"

  # Change the port
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat udp4-listen:1337 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device set proxyTester proxyDev connect udp:127.0.0.1:1337
  sleep 0.2

  ECHO=$( (echo "${MESSAGE}" ; sleep 0.1) | socat - unix:"${HOST_SOCK}")
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart when config was updated"
    false
  fi

  rm -f "${HOST_SOCK}"

  # Cleanup
  lxc delete -f proxyTester
}

container_devices_proxy_tcp_udp() {
  echo "====> Testing tcp to udp proxying"

  # Setup
  MESSAGE="Proxy device test string: tcp -> udp"
  lxc launch testimage proxyTester

  # Initial test
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat udp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device add proxyTester proxyDev proxy "listen=tcp:127.0.0.1:$HOST_TCP_PORT" connect=udp:127.0.0.1:4321 bind=host
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly send data from host to container"
    false
  fi

  # Restart the container
  lxc restart -f proxyTester
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat udp4-listen:4321 exec:/bin/cat &
  NSENTER_PID=$!
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart on container restart"
    false
  fi

  # Change the port
  nsenter -n -U -t "$(lxc query /1.0/instances/proxyTester/state | jq --exit-status .pid)" -- socat udp4-listen:1337 exec:/bin/cat &
  NSENTER_PID=$!
  lxc config device set proxyTester proxyDev connect udp:127.0.0.1:1337
  sleep 0.2

  ECHO=$( echo "${MESSAGE}" | socat - tcp4:127.0.0.1:"${HOST_TCP_PORT}",shut-down)
  kill "${NSENTER_PID}" 2>/dev/null || true
  wait "${NSENTER_PID}" 2>/dev/null || true

  if [ "${ECHO}" != "${MESSAGE}" ]; then
    cat "${LXD_DIR}/logs/proxyTester/proxy.proxyDev.log"
    echo "Proxy device did not properly restart when config was updated"
    false
  fi

  # Cleanup
  lxc delete -f proxyTester
}

container_devices_proxy_with_overlapping_forward_net() {
  echo "====> Testing proxy creation with overlapping network forward"

  netName="testnet"

  lxc network create "${netName}" \
        ipv4.address=192.0.2.1/24 \
        ipv6.address=none

  overlappingAddr="192.0.2.2"
  proxyTesterStaticIP="192.0.2.3"

  # First, launch container with a static IP
  lxc launch testimage proxyTester
  lxc config device add proxyTester eth0 nic \
    nictype=bridged \
    name=eth0 \
    parent="${netName}" \
    ipv4.address="${proxyTesterStaticIP}"

  # Check creating empty forward doesn't create any firewall rules.
  lxc network forward create "${netName}" "${overlappingAddr}"

  # Test overlapping issue (network forward exists --> proxy creation should fail)
  ! lxc config device add proxyTester proxyDev proxy "listen=tcp:${overlappingAddr}:$HOST_TCP_PORT" "connect=tcp:${proxyTesterStaticIP}:4321" nat=true || false

  # Intermediary cleanup
  lxc delete -f proxyTester
  lxc network forward delete "${netName}" "${overlappingAddr}"

  # Same operations as before but in the reverse order
  lxc launch testimage proxyTester
  lxc config device add proxyTester eth0 nic \
    nictype=bridged \
    name=eth0 \
    parent="${netName}" \
    ipv4.address="${proxyTesterStaticIP}"

  lxc config device add proxyTester proxyDev proxy "listen=tcp:${overlappingAddr}:$HOST_TCP_PORT" "connect=tcp:${proxyTesterStaticIP}:4321" nat=true

  # Test overlapping issue (proxy exists --> network forward creation should fail)
  ! lxc network forward create "${netName}" "${overlappingAddr}" || false

  # Final cleanup
  lxc delete -f proxyTester
  lxc network delete "${netName}"
}
