package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"

	deviceConfig "github.com/canonical/lxd/lxd/device/config"
	"github.com/canonical/lxd/lxd/network"
)

func TestParseAddr(t *testing.T) {
	tests := []struct {
		name       string
		address    string
		expected   *deviceConfig.ProxyAddress
		shouldFail bool
	}{
		// Port testing
		{
			"Single port",
			"tcp:127.0.0.1:2000",
			&deviceConfig.ProxyAddress{
				ConnType: "tcp",
				Address:  "127.0.0.1",
				Ports:    []uint64{2000},
				Abstract: false,
			},
			false,
		},
		{
			"Multiple ports",
			"tcp:127.0.0.1:2000,2002",
			&deviceConfig.ProxyAddress{
				ConnType: "tcp",
				Address:  "127.0.0.1",
				Ports: []uint64{
					2000,
					2002,
				},
				Abstract: false,
			},
			false,
		},
		{
			"Port range",
			"tcp:127.0.0.1:2000-2002",
			&deviceConfig.ProxyAddress{
				ConnType: "tcp",
				Address:  "127.0.0.1",
				Ports: []uint64{
					2000,
					2001,
					2002,
				},
				Abstract: false,
			},
			false,
		},
		{
			"Mixed ports and port ranges",
			"tcp:127.0.0.1:2000,2002,3000-3003,4000-4003",
			&deviceConfig.ProxyAddress{
				ConnType: "tcp",
				Address:  "127.0.0.1",
				Ports: []uint64{
					2000,
					2002,
					3000,
					3001,
					3002,
					3003,
					4000,
					4001,
					4002,
					4003,
				},
				Abstract: false,
			},
			false,
		},
		// connType testing
		{
			"UDP",
			"udp:127.0.0.1:2000",
			&deviceConfig.ProxyAddress{
				ConnType: "udp",
				Address:  "127.0.0.1",
				Ports:    []uint64{2000},
				Abstract: false,
			},
			false,
		},
		{
			"Unix socket",
			"unix:/foobar",
			&deviceConfig.ProxyAddress{
				ConnType: "unix",
				Address:  "/foobar",
				Abstract: false,
			},
			false,
		},
		{
			"Abstract unix socket",
			"unix:@/foobar",
			&deviceConfig.ProxyAddress{
				ConnType: "unix",
				Address:  "@/foobar",
				Abstract: true,
			},
			false,
		},
		{
			"Unknown connection type",
			"bla:blub",
			nil,
			true,
		},
		// Address testing
		{
			"Valid IPv6 address (1)",
			"tcp:[fd39:2561:7238:91b5:0:0:0:0]:2000",
			&deviceConfig.ProxyAddress{
				ConnType: "tcp",
				Address:  "fd39:2561:7238:91b5:0:0:0:0",
				Ports:    []uint64{2000},
				Abstract: false,
			},
			false,
		},
		{
			"Valid IPv6 address (2)",
			"tcp:[fd39:2561:7238:91b5::0]:2000",
			&deviceConfig.ProxyAddress{
				ConnType: "tcp",
				Address:  "fd39:2561:7238:91b5::0",
				Ports:    []uint64{2000},
				Abstract: false,
			},
			false,
		},
		{
			"Valid IPv6 address (3)",
			"tcp:[::1]:2000",
			&deviceConfig.ProxyAddress{
				ConnType: "tcp",
				Address:  "::1",
				Ports:    []uint64{2000},
				Abstract: false,
			},
			false,
		},
		{
			"Valid IPv6 address (4)",
			"tcp:[::]:2000",
			&deviceConfig.ProxyAddress{
				ConnType: "tcp",
				Address:  "::",
				Ports:    []uint64{2000},
				Abstract: false,
			},
			false,
		},
		{
			"Invalid IPv6 address (1)",
			"tcp:fd39:2561:7238:91b5:0:0:0:0:2000",
			nil,
			true,
		},
		{
			"Invalid IPv6 address (2)",
			"tcp:fd39:2561:7238:91b5::0:2000",
			nil,
			true,
		},
	}

	for i, tt := range tests {
		log.Printf("Running test #%d: %s", i, tt.name)
		addr, err := network.ProxyParseAddr(tt.address)
		if tt.shouldFail {
			require.Error(t, err)
			require.Nil(t, addr)
			continue
		}

		require.NoError(t, err)
		require.Equal(t, tt.expected, addr)
	}
}

func testStreamPair(t testing.TB, network string) (proxy net.Conn, peer net.Conn) {
	t.Helper()

	switch network {
	case "tcp":
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		require.NoError(t, err)
		t.Cleanup(func() { _ = listener.Close() })

		client, err := net.Dial("tcp4", listener.Addr().String())
		require.NoError(t, err)
		t.Cleanup(func() { _ = client.Close() })

		server, err := listener.Accept()
		require.NoError(t, err)
		t.Cleanup(func() { _ = server.Close() })

		return server, client
	case "unix":
		address := filepath.Join(t.TempDir(), "proxy.sock")
		listener, err := net.Listen("unix", address)
		require.NoError(t, err)
		t.Cleanup(func() { _ = listener.Close() })

		client, err := net.Dial("unix", address)
		require.NoError(t, err)
		t.Cleanup(func() { _ = client.Close() })

		server, err := listener.Accept()
		require.NoError(t, err)
		t.Cleanup(func() { _ = server.Close() })

		return server, client
	default:
		t.Fatalf("Unknown network %q", network)
		return nil, nil
	}
}

func BenchmarkProxyStreamCopy(b *testing.B) {
	implementations := []struct {
		name string
		copy func(net.Conn, net.Conn) error
	}{
		{
			name: "buffered",
			copy: proxyCopy,
		},
		{
			name: "io.Copy",
			copy: func(dst net.Conn, src net.Conn) error {
				_, err := io.Copy(dst, src)
				return err
			},
		},
	}

	connections := []struct {
		name string
		src  string
		dst  string
	}{
		{name: "TCP-TCP", src: "tcp", dst: "tcp"},
		{name: "TCP-Unix", src: "tcp", dst: "unix"},
		{name: "Unix-TCP", src: "unix", dst: "tcp"},
	}

	data := make([]byte, 16<<20)
	for _, connection := range connections {
		for _, implementation := range implementations {
			b.Run(connection.name+"/"+implementation.name, func(b *testing.B) {
				b.ReportAllocs()
				b.SetBytes(int64(len(data)))

				for range b.N {
					srcProxy, srcPeer := testStreamPair(b, connection.src)
					dstProxy, dstPeer := testStreamPair(b, connection.dst)

					copyDone := make(chan error, 1)
					go func() {
						err := implementation.copy(dstProxy, srcProxy)
						_ = dstProxy.(closeWriter).CloseWrite()
						copyDone <- err
					}()

					readDone := make(chan error, 1)
					go func() {
						_, err := io.Copy(io.Discard, dstPeer)
						readDone <- err
					}()

					_, err := srcPeer.Write(data)
					if err != nil {
						b.Fatal(err)
					}

					err = srcPeer.(closeWriter).CloseWrite()
					if err != nil {
						b.Fatal(err)
					}

					err = <-copyDone
					if err != nil {
						b.Fatal(err)
					}

					err = <-readDone
					if err != nil {
						b.Fatal(err)
					}

					_ = srcProxy.Close()
					_ = dstProxy.Close()
					_ = srcPeer.Close()
					_ = dstPeer.Close()
				}
			})
		}
	}
}

func TestRelayHalfClose(t *testing.T) {
	tests := []struct {
		name  string
		left  string
		right string
	}{
		{name: "TCP to TCP", left: "tcp", right: "tcp"},
		{name: "TCP to Unix", left: "tcp", right: "unix"},
		{name: "Unix to TCP", left: "unix", right: "tcp"},
		{name: "Unix to Unix", left: "unix", right: "unix"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			leftProxy, leftPeer := testStreamPair(t, test.left)
			rightProxy, rightPeer := testStreamPair(t, test.right)
			deadline := time.Now().Add(5 * time.Second)
			require.NoError(t, leftPeer.SetDeadline(deadline))
			require.NoError(t, rightPeer.SetDeadline(deadline))

			relayDone := make(chan struct{})
			go func() {
				if test.left == "unix" && test.right == "unix" {
					unixRelay(leftProxy, rightProxy)
				} else {
					genericRelay(leftProxy, rightProxy)
				}

				close(relayDone)
			}()

			_, err := leftPeer.Write([]byte("request"))
			require.NoError(t, err)

			leftWriter, ok := leftPeer.(closeWriter)
			require.True(t, ok)
			err = leftWriter.CloseWrite()
			require.NoError(t, err)

			request, err := io.ReadAll(rightPeer)
			require.NoError(t, err)
			require.Equal(t, "request", string(request))

			_, err = rightPeer.Write([]byte("response"))
			require.NoError(t, err)

			rightWriter, ok := rightPeer.(closeWriter)
			require.True(t, ok)
			err = rightWriter.CloseWrite()
			require.NoError(t, err)

			response, err := io.ReadAll(leftPeer)
			require.NoError(t, err)
			require.Equal(t, "response", string(response))

			select {
			case <-relayDone:
			case <-time.After(5 * time.Second):
				t.Fatal("Relay did not stop after both sides closed")
			}
		})
	}
}

func TestRelayCopyError(t *testing.T) {
	tests := []struct {
		name     string
		left     string
		right    string
		resetEnd string
	}{
		{name: "TCP to TCP", left: "tcp", right: "tcp", resetEnd: "left"},
		{name: "TCP to Unix", left: "tcp", right: "unix", resetEnd: "left"},
		{name: "Unix to TCP", left: "unix", right: "tcp", resetEnd: "right"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			leftProxy, leftPeer := testStreamPair(t, test.left)
			rightProxy, rightPeer := testStreamPair(t, test.right)

			relayDone := make(chan struct{})
			go func() {
				genericRelay(leftProxy, rightProxy)
				close(relayDone)
			}()

			resetPeer := leftPeer
			if test.resetEnd == "right" {
				resetPeer = rightPeer
			}

			tcpPeer := resetPeer.(*net.TCPConn)
			require.NoError(t, tcpPeer.SetLinger(0))
			require.NoError(t, tcpPeer.Close())

			select {
			case <-relayDone:
			case <-time.After(5 * time.Second):
				t.Fatal("Relay did not stop after a connection reset")
			}
		})
	}
}

func countOpenFDsForPath(t *testing.T, path string) int {
	t.Helper()

	entries, err := os.ReadDir("/proc/self/fd")
	require.NoError(t, err)

	count := 0
	for _, entry := range entries {
		target, err := os.Readlink(filepath.Join("/proc/self/fd", entry.Name()))
		if err != nil {
			continue
		}

		if target == path {
			count++
		}
	}

	return count
}

func TestUnixRelayClosesRightsOnError(t *testing.T) {
	leftProxy, leftPeer := testStreamPair(t, "unix")
	rightProxy, rightPeer := testStreamPair(t, "unix")

	leftUnix := leftPeer.(*net.UnixConn)
	_ = rightPeer.Close()

	file, err := os.CreateTemp(t.TempDir(), "rights")
	require.NoError(t, err)
	t.Cleanup(func() { _ = file.Close() })

	relayDone := make(chan struct{})
	go func() {
		unixRelay(leftProxy, rightProxy)
		close(relayDone)
	}()

	n, oobn, err := leftUnix.WriteMsgUnix([]byte{1}, unix.UnixRights(int(file.Fd())), nil)
	require.NoError(t, err)
	require.Equal(t, 1, n)
	require.Positive(t, oobn)

	require.NoError(t, leftUnix.CloseWrite())
	select {
	case <-relayDone:
	case <-time.After(5 * time.Second):
		t.Fatal("Relay did not stop after both sides closed")
	}

	require.Eventually(t, func() bool {
		return countOpenFDsForPath(t, file.Name()) == 1
	}, 5*time.Second, 10*time.Millisecond)
}

func TestRelayUDP(t *testing.T) {
	type relay struct {
		listener *net.UDPConn
		target   *net.UDPConn
		prefix   string
	}

	relays := make([]relay, 2)
	for i := range relays {
		proxyListener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
		require.NoError(t, err)
		t.Cleanup(func() { _ = proxyListener.Close() })

		targetListener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
		require.NoError(t, err)
		t.Cleanup(func() { _ = targetListener.Close() })

		listenerFile, err := proxyListener.File()
		require.NoError(t, err)
		t.Cleanup(func() { _ = listenerFile.Close() })

		listenerConn, err := net.FileConn(listenerFile)
		require.NoError(t, err)
		t.Cleanup(func() { _ = listenerConn.Close() })

		targetConn, err := net.DialUDP("udp4", nil, targetListener.LocalAddr().(*net.UDPAddr))
		require.NoError(t, err)
		t.Cleanup(func() { _ = targetConn.Close() })

		prefix := fmt.Sprintf("target-%d:", i)
		relays[i] = relay{
			listener: proxyListener,
			target:   targetListener,
			prefix:   prefix,
		}
		go genericRelay(listenerConn, targetConn)

		go func() {
			buf := make([]byte, 64)
			n, clientAddr, err := targetListener.ReadFromUDP(buf)
			if err != nil {
				return
			}

			response := append([]byte(prefix), buf[:n]...)
			_, _ = targetListener.WriteToUDP(response, clientAddr)
		}()
	}

	client, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	require.NoError(t, err)
	t.Cleanup(func() { _ = client.Close() })

	deadline := time.Now().Add(5 * time.Second)
	require.NoError(t, client.SetDeadline(deadline))
	for i := range relays {
		require.NoError(t, relays[i].target.SetDeadline(deadline))
		_, err = client.WriteToUDP([]byte("datagram"), relays[i].listener.LocalAddr().(*net.UDPAddr))
		require.NoError(t, err)
	}

	responses := make(map[string]bool)
	for range relays {
		buf := make([]byte, 64)
		n, _, err := client.ReadFromUDP(buf)
		require.NoError(t, err)
		responses[string(buf[:n])] = true
	}

	require.Equal(t, map[string]bool{
		"target-0:datagram": true,
		"target-1:datagram": true,
	}, responses)

	udpSessionsLock.Lock()
	for key, session := range udpSessions {
		session.timer.Stop()
		_ = session.target.Close()
		delete(udpSessions, key)
	}

	udpSessionsLock.Unlock()
}
