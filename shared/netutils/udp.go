package netutils

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
	"time"
)

const maxUDPFrameSize = 65535

// WriteUDPFrame writes a length-prefixed UDP datagram to a stream.
func WriteUDPFrame(w io.Writer, data []byte) error {
	if len(data) > maxUDPFrameSize {
		return errors.New("UDP datagram is too large")
	}

	header := make([]byte, 2)
	binary.BigEndian.PutUint16(header, uint16(len(data)))
	err := writeAll(w, header)
	if err != nil {
		return err
	}

	return writeAll(w, data)
}

func writeAll(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := w.Write(data)
		if err != nil {
			return err
		}

		if n == 0 {
			return io.ErrShortWrite
		}

		data = data[n:]
	}

	return nil
}

// ReadUDPFrame reads a length-prefixed UDP datagram from a stream.
func ReadUDPFrame(r io.Reader) ([]byte, error) {
	header := make([]byte, 2)
	_, err := io.ReadFull(r, header)
	if err != nil {
		return nil, err
	}

	size := int(binary.BigEndian.Uint16(header))
	data := make([]byte, size)
	_, err = io.ReadFull(r, data)
	if err != nil {
		return nil, err
	}

	return data, nil
}

// RelayUDPConnected relays UDP datagrams between a connected UDP socket and a framed stream.
func RelayUDPConnected(stream net.Conn, udp net.Conn) {
	defer func() { _ = stream.Close() }()
	defer func() { _ = udp.Close() }()

	done := make(chan struct{}, 2)
	go func() {
		buf := make([]byte, maxUDPFrameSize)
		for {
			n, err := udp.Read(buf)
			if err != nil {
				break
			}

			err = WriteUDPFrame(stream, buf[:n])
			if err != nil {
				break
			}
		}

		done <- struct{}{}
	}()

	go func() {
		for {
			data, err := ReadUDPFrame(stream)
			if err != nil {
				break
			}

			_, err = udp.Write(data)
			if err != nil {
				break
			}
		}

		done <- struct{}{}
	}()

	<-done
	_ = stream.Close()
	_ = udp.Close()
	<-done
}

type udpProxySession struct {
	client net.Addr
	stream net.Conn
	timer  *time.Timer
}

// ProxyUDP forwards datagrams from a UDP listener through independently framed stream connections.
func ProxyUDP(listener *net.UDPConn, connect func() (net.Conn, error), timeout time.Duration, onError func(error)) error {
	sessions := make(map[string]*udpProxySession)
	sessionsMu := sync.Mutex{}

	remove := func(key string, session *udpProxySession) {
		sessionsMu.Lock()
		current, ok := sessions[key]
		if ok && current == session {
			delete(sessions, key)
		}

		sessionsMu.Unlock()
		_ = session.stream.Close()
	}

	defer func() {
		sessionsMu.Lock()
		for key, session := range sessions {
			session.timer.Stop()
			_ = session.stream.Close()
			delete(sessions, key)
		}

		sessionsMu.Unlock()
	}()

	buf := make([]byte, maxUDPFrameSize)
	for {
		n, client, err := listener.ReadFrom(buf)
		if err != nil {
			return err
		}

		key := client.String()
		sessionsMu.Lock()
		session := sessions[key]
		sessionsMu.Unlock()

		if session == nil {
			stream, err := connect()
			if err != nil {
				if onError != nil {
					onError(err)
				}

				continue
			}

			session = &udpProxySession{
				client: client,
				stream: stream,
			}
			session.timer = time.AfterFunc(timeout, func() { remove(key, session) })

			sessionsMu.Lock()
			sessions[key] = session
			sessionsMu.Unlock()

			go func() {
				defer remove(key, session)

				for {
					data, err := ReadUDPFrame(session.stream)
					if err != nil {
						return
					}

					_, err = listener.WriteTo(data, session.client)
					if err != nil {
						return
					}

					session.timer.Reset(timeout)
				}
			}()
		}

		err = WriteUDPFrame(session.stream, buf[:n])
		if err != nil {
			remove(key, session)
			continue
		}

		session.timer.Reset(timeout)
	}
}
