package main

import (
	"io"
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestRelayProxyConnectionsHalfClose(t *testing.T) {
	pair := func() (net.Conn, net.Conn) {
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
	}

	left, leftPeer := pair()
	right, rightPeer := pair()
	deadline := time.Now().Add(5 * time.Second)
	require.NoError(t, leftPeer.SetDeadline(deadline))
	require.NoError(t, rightPeer.SetDeadline(deadline))

	done := make(chan struct{})
	go func() {
		relayProxyConnections(left, right)
		close(done)
	}()

	_, err := leftPeer.Write([]byte("request"))
	require.NoError(t, err)

	leftWriter, ok := leftPeer.(*net.TCPConn)
	require.True(t, ok)
	err = leftWriter.CloseWrite()
	require.NoError(t, err)

	request, err := io.ReadAll(rightPeer)
	require.NoError(t, err)
	require.Equal(t, "request", string(request))

	_, err = rightPeer.Write([]byte("response"))
	require.NoError(t, err)

	rightWriter, ok := rightPeer.(*net.TCPConn)
	require.True(t, ok)
	err = rightWriter.CloseWrite()
	require.NoError(t, err)

	response, err := io.ReadAll(leftPeer)
	require.NoError(t, err)
	require.Equal(t, "response", string(response))

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Relay did not stop after both sides closed")
	}
}
