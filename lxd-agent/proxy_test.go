package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	deviceConfig "github.com/canonical/lxd/lxd/device/config"
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

func TestProxyUnixListenerOwnership(t *testing.T) {
	path := filepath.Join(t.TempDir(), "proxy.sock")
	addr := &deviceConfig.ProxyAddress{
		ConnType: "unix",
		Address:  path,
	}

	original, err := proxyListen(addr, "", "", "")
	require.NoError(t, err)

	_, err = proxyListen(addr, "", "", "")
	require.Error(t, err)
	require.FileExists(t, path)

	require.NoError(t, os.Remove(path))
	replacement, err := net.Listen("unix", path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = replacement.Close() })

	require.NoError(t, original.Close())

	conn, err := net.DialTimeout("unix", path, time.Second)
	require.NoError(t, err)
	require.NoError(t, conn.Close())
}

func TestProxyUnixListenerOperationsAreSerialized(t *testing.T) {
	path := filepath.Join(t.TempDir(), "proxy.sock")
	addr := &deviceConfig.ProxyAddress{
		ConnType: "unix",
		Address:  path,
	}

	listener, err := proxyListen(addr, "", "", "")
	require.NoError(t, err)

	proxyUnixListenerMu.Lock()
	closeStarted := make(chan struct{})
	closeDone := make(chan error, 1)
	go func() {
		close(closeStarted)
		closeDone <- listener.Close()
	}()
	<-closeStarted

	select {
	case err := <-closeDone:
		proxyUnixListenerMu.Unlock()
		require.Fail(t, "Listener close was not serialized", err)
	case <-time.After(20 * time.Millisecond):
	}

	proxyUnixListenerMu.Unlock()
	require.NoError(t, <-closeDone)
}
