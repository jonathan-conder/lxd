package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mdlayher/vsock"

	deviceConfig "github.com/canonical/lxd/lxd/device/config"
	"github.com/canonical/lxd/lxd/response"
	"github.com/canonical/lxd/shared"
	"github.com/canonical/lxd/shared/netutils"
)

var proxyCmd = APIEndpoint{
	Name: "proxy",
	Path: "proxy",
	Get:  APIEndpointAction{Handler: proxyHandler},
}

func proxyHandler(d *Daemon, r *http.Request) response.Response {
	mode := r.URL.Query().Get("mode")
	address := r.URL.Query().Get("address")
	addr, err := deviceConfig.ParseProxyAddress(address)
	if err != nil {
		return response.BadRequest(err)
	}

	switch mode {
	case "connect":
		target, err := proxyDial(addr, 0)
		if err != nil {
			return response.BadRequest(err)
		}

		return &proxyConnectServe{
			target: target,
			framed: shared.IsTrue(r.URL.Query().Get("framed")),
		}
	case "listen":
		cid, err := strconv.ParseUint(r.URL.Query().Get("cid"), 10, 32)
		if err != nil {
			return response.BadRequest(fmt.Errorf("Invalid host context ID: %w", err))
		}

		port, err := strconv.ParseUint(r.URL.Query().Get("port"), 10, 32)
		if err != nil || port == 0 {
			return response.BadRequest(errors.New("Invalid host vsock port"))
		}

		serve := &proxyListenServe{
			hostCID:       uint32(cid),
			hostPort:      uint32(port),
			proxyProtocol: shared.IsTrue(r.URL.Query().Get("proxy_protocol")),
			token:         r.URL.Query().Get("token"),
		}

		if addr.ConnType == "udp" {
			serve.udp, err = proxyListenUDP(addr)
		} else {
			serve.listener, err = proxyListen(addr, r.URL.Query().Get("mode_file"), r.URL.Query().Get("uid"), r.URL.Query().Get("gid"))
		}

		if err != nil {
			return response.BadRequest(err)
		}

		return serve
	default:
		return response.BadRequest(errors.New("Invalid proxy mode"))
	}
}

func proxyAddress(addr *deviceConfig.ProxyAddress, portIndex int) string {
	if addr.ConnType == "unix" {
		return addr.Address
	}

	port := addr.Ports[0]
	if len(addr.Ports) > 1 {
		port = addr.Ports[portIndex]
	}

	return net.JoinHostPort(addr.Address, strconv.FormatUint(port, 10))
}

func proxyDial(addr *deviceConfig.ProxyAddress, portIndex int) (net.Conn, error) {
	return net.Dial(addr.ConnType, proxyAddress(addr, portIndex))
}

func proxyListenUDP(addr *deviceConfig.ProxyAddress) (*net.UDPConn, error) {
	udpAddr, err := net.ResolveUDPAddr("udp", proxyAddress(addr, 0))
	if err != nil {
		return nil, err
	}

	return net.ListenUDP("udp", udpAddr)
}

func proxyListen(addr *deviceConfig.ProxyAddress, mode string, uid string, gid string) (net.Listener, error) {
	if addr.ConnType == "unix" && !addr.Abstract {
		err := os.Remove(addr.Address)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}

	listener, err := net.Listen(addr.ConnType, proxyAddress(addr, 0))
	if err != nil {
		return nil, err
	}

	if addr.ConnType != "unix" || addr.Abstract {
		return listener, nil
	}

	revert := true
	defer func() {
		if revert {
			_ = listener.Close()
		}
	}()

	fileUID := -1
	if uid != "" {
		fileUID, err = strconv.Atoi(uid)
		if err != nil {
			return nil, err
		}
	}

	fileGID := -1
	if gid != "" {
		fileGID, err = strconv.Atoi(gid)
		if err != nil {
			return nil, err
		}
	}

	if fileUID != -1 || fileGID != -1 {
		err = os.Chown(addr.Address, fileUID, fileGID)
		if err != nil {
			return nil, err
		}
	}

	if mode != "" {
		parsedMode, err := strconv.ParseUint(mode, 8, 32)
		if err != nil {
			return nil, err
		}

		err = os.Chmod(addr.Address, os.FileMode(parsedMode))
		if err != nil {
			return nil, err
		}
	}

	revert = false
	return listener, nil
}

type proxyConnectServe struct {
	target net.Conn
	framed bool
}

func (r *proxyConnectServe) String() string {
	return "VM proxy connection"
}

func (r *proxyConnectServe) Render(w http.ResponseWriter, request *http.Request) error {
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		_ = r.target.Close()
		return errors.New("Webserver does not support hijacking")
	}

	conn, _, err := hijacker.Hijack()
	if err != nil {
		_ = r.target.Close()
		return err
	}

	err = response.Upgrade(conn, "lxd-proxy-connect")
	if err != nil {
		_ = conn.Close()
		_ = r.target.Close()
		return err
	}

	if r.framed {
		netutils.RelayUDPConnected(conn, r.target)
	} else {
		relayProxyConnections(conn, r.target)
	}

	return nil
}

type proxyListenServe struct {
	listener      net.Listener
	udp           *net.UDPConn
	hostCID       uint32
	hostPort      uint32
	proxyProtocol bool
	token         string
}

func (r *proxyListenServe) closeListener() error {
	if r.listener != nil {
		return r.listener.Close()
	}

	if r.udp != nil {
		return r.udp.Close()
	}

	return nil
}

func (r *proxyListenServe) String() string {
	return "VM proxy listener"
}

func (r *proxyListenServe) Render(w http.ResponseWriter, request *http.Request) error {
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		_ = r.closeListener()
		return errors.New("Webserver does not support hijacking")
	}

	control, _, err := hijacker.Hijack()
	if err != nil {
		_ = r.closeListener()
		return err
	}

	err = response.Upgrade(control, "lxd-proxy-listen")
	if err != nil {
		_ = control.Close()
		_ = r.closeListener()
		return err
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if r.udp != nil {
		done := make(chan error, 1)
		go func() {
			done <- netutils.ProxyUDP(r.udp, func() (net.Conn, error) {
				callback, err := vsock.DialContext(ctx, r.hostCID, r.hostPort, nil)
				if err != nil {
					return nil, err
				}

				_, err = io.WriteString(callback, r.token)
				if err != nil {
					_ = callback.Close()
					return nil, err
				}

				return callback, nil
			}, 30*time.Minute, nil)
		}()

		_, _ = io.Copy(io.Discard, control)
		cancel()
		_ = r.udp.Close()
		err = <-done
		if err != nil && !errors.Is(err, net.ErrClosed) {
			return err
		}

		return nil
	}

	accepted := make(chan net.Conn)
	done := make(chan struct{})
	listenerClosed := make(chan struct{})
	go func() {
		defer close(listenerClosed)
		for {
			conn, err := r.listener.Accept()
			if err != nil {
				return
			}

			select {
			case accepted <- conn:
			case <-done:
				_ = conn.Close()
				return
			}
		}
	}()

	controlClosed := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, control)
		close(controlClosed)
	}()

	var conns sync.Map
	closeConnections := func() {
		conns.Range(func(key any, value any) bool {
			_ = key.(net.Conn).Close()
			callback, ok := value.(net.Conn)
			if ok {
				_ = callback.Close()
			}

			return true
		})
	}

	for {
		select {
		case <-controlClosed:
			cancel()
			close(done)
			_ = r.listener.Close()
			closeConnections()

			return nil
		case <-listenerClosed:
			cancel()
			close(done)
			_ = control.Close()
			closeConnections()
			return nil
		case conn := <-accepted:
			go func(conn net.Conn) {
				conns.Store(conn, nil)
				defer conns.Delete(conn)

				callback, err := vsock.DialContext(ctx, r.hostCID, r.hostPort, nil)
				if err != nil {
					_ = conn.Close()
					return
				}

				select {
				case <-done:
					_ = conn.Close()
					_ = callback.Close()
					return
				default:
				}

				conns.Store(conn, callback)

				select {
				case <-done:
					_ = conn.Close()
					_ = callback.Close()
					return
				default:
				}

				_, err = io.WriteString(callback, r.token)
				if err != nil {
					_ = conn.Close()
					_ = callback.Close()
					return
				}

				if r.proxyProtocol {
					header := proxyProtocolHeader(conn)
					_, err = io.WriteString(callback, header)
					if err != nil {
						_ = conn.Close()
						_ = callback.Close()
						return
					}
				}

				relayProxyConnections(conn, callback)
			}(conn)
		}
	}
}

func proxyProtocolHeader(conn net.Conn) string {
	if conn.LocalAddr().Network() != "tcp" && conn.LocalAddr().Network() != "tcp4" && conn.LocalAddr().Network() != "tcp6" {
		return "PROXY UNKNOWN\r\n"
	}

	clientHost, clientPort, err := net.SplitHostPort(conn.RemoteAddr().String())
	if err != nil {
		return "PROXY UNKNOWN\r\n"
	}

	destHost, destPort, err := net.SplitHostPort(conn.LocalAddr().String())
	if err != nil {
		return "PROXY UNKNOWN\r\n"
	}

	proto := "TCP4"
	if strings.Contains(clientHost, ":") {
		proto = "TCP6"
	}

	return fmt.Sprintf("PROXY %s %s %s %s %s\r\n", proto, clientHost, destHost, clientPort, destPort)
}

type proxyCloseWriter interface {
	CloseWrite() error
}

func relayProxyConnections(left net.Conn, right net.Conn) {
	defer func() { _ = left.Close() }()
	defer func() { _ = right.Close() }()

	done := make(chan error, 2)
	copyConn := func(src net.Conn, dst net.Conn) {
		_, err := io.Copy(dst, src)
		if err == nil {
			closeWriter, ok := dst.(proxyCloseWriter)
			if ok {
				err = closeWriter.CloseWrite()
			}
		}

		done <- err
	}

	go copyConn(left, right)
	go copyConn(right, left)

	err := <-done
	if err != nil {
		_ = left.Close()
		_ = right.Close()
	}

	err = <-done
	if err != nil {
		_ = left.Close()
		_ = right.Close()
	}
}
