package netutils

import (
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestRelayUDPConnected(t *testing.T) {
	targetAddr := &net.UDPAddr{IP: net.ParseIP("127.0.0.1")}
	target, err := net.ListenUDP("udp4", targetAddr)
	require.NoError(t, err)
	t.Cleanup(func() { _ = target.Close() })

	udp, err := net.DialUDP("udp4", nil, target.LocalAddr().(*net.UDPAddr))
	require.NoError(t, err)
	t.Cleanup(func() { _ = udp.Close() })

	stream, peer := net.Pipe()
	t.Cleanup(func() { _ = stream.Close() })
	t.Cleanup(func() { _ = peer.Close() })
	go RelayUDPConnected(stream, udp)

	err = WriteUDPFrame(peer, []byte("request"))
	require.NoError(t, err)

	buf := make([]byte, 64)
	deadline := time.Now().Add(5 * time.Second)
	require.NoError(t, target.SetDeadline(deadline))
	n, client, err := target.ReadFromUDP(buf)
	require.NoError(t, err)
	require.Equal(t, "request", string(buf[:n]))

	_, err = target.WriteToUDP([]byte("response"), client)
	require.NoError(t, err)

	response, err := ReadUDPFrame(peer)
	require.NoError(t, err)
	require.Equal(t, "response", string(response))
}

func TestProxyUDP(t *testing.T) {
	listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	require.NoError(t, err)

	stream, peer := net.Pipe()
	t.Cleanup(func() { _ = stream.Close() })
	t.Cleanup(func() { _ = peer.Close() })

	done := make(chan error, 1)
	go func() {
		done <- ProxyUDP(listener, func() (net.Conn, error) {
			return stream, nil
		}, time.Minute, nil)
	}()

	client, err := net.DialUDP("udp4", nil, listener.LocalAddr().(*net.UDPAddr))
	require.NoError(t, err)
	t.Cleanup(func() { _ = client.Close() })

	_, err = client.Write([]byte("request"))
	require.NoError(t, err)

	request, err := ReadUDPFrame(peer)
	require.NoError(t, err)
	require.Equal(t, "request", string(request))

	err = WriteUDPFrame(peer, []byte("response"))
	require.NoError(t, err)

	buf := make([]byte, 64)
	require.NoError(t, client.SetReadDeadline(time.Now().Add(5*time.Second)))
	n, err := client.Read(buf)
	require.NoError(t, err)
	require.Equal(t, "response", string(buf[:n]))

	_ = listener.Close()
	err = <-done
	require.Error(t, err)
}
