package config

import (
	"errors"
	"fmt"
	"net"
	"slices"
	"strconv"
	"strings"

	"github.com/canonical/lxd/shared/validate"
)

// ProxyAddress represents a proxy address configuration.
type ProxyAddress struct {
	ConnType string
	Abstract bool
	Address  string
	Ports    []uint64
}

// ParseProxyAddress validates and parses a proxy address.
func ParseProxyAddress(data string) (*ProxyAddress, error) {
	connType, addr, found := strings.Cut(data, ":")
	if !slices.Contains([]string{"tcp", "udp", "unix"}, connType) {
		return nil, fmt.Errorf("Unknown protocol type %q", connType)
	}

	if !found || addr == "" {
		return nil, errors.New("Missing address")
	}

	proxyAddr := &ProxyAddress{
		ConnType: connType,
		Abstract: strings.HasPrefix(addr, "@"),
	}

	if proxyAddr.ConnType == "unix" {
		proxyAddr.Address = addr
		return proxyAddr, nil
	}

	address, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}

	err = validate.Optional(validate.IsNetworkAddress)(address)
	if err != nil {
		return nil, err
	}

	proxyAddr.Address = address
	ports := strings.Split(port, ",")
	proxyAddr.Ports = make([]uint64, 0, len(ports))

	for _, portSpec := range ports {
		portFirst, portRange, err := parseProxyPortRange(portSpec)
		if err != nil {
			return nil, err
		}

		for i := range portRange {
			proxyAddr.Ports = append(proxyAddr.Ports, uint64(portFirst+i))
		}
	}

	if len(proxyAddr.Ports) <= 0 {
		return nil, errors.New("At least one port is required")
	}

	return proxyAddr, nil
}

func parseProxyPortRange(r string) (base int64, size int64, err error) {
	baseStr, endStr, found := strings.Cut(r, "-")

	base, err = strconv.ParseInt(baseStr, 10, 64)
	if err != nil {
		return -1, -1, err
	}

	size = 1
	if found {
		if strings.Contains(endStr, "-") {
			return -1, -1, fmt.Errorf("Invalid port range %q", r)
		}

		size, err = strconv.ParseInt(endStr, 10, 64)
		if err != nil {
			return -1, -1, err
		}

		if size <= base {
			return -1, -1, errors.New("End port should be higher than start port")
		}

		size -= base
		size++
	}

	return base, size, nil
}
