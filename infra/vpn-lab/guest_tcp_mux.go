// Test infrastructure only: guest loopback TCP over an already owned Tart RPC
// stdin/stdout stream. No host IP route, VPN process or working credential.
// Frame: kind(1), connection ID(4), payload length(4), opaque bytes. Bounds:
// eight loopback clients, 64KiB frame, three-hour process lifetime.
package main

import (
	"encoding/binary"
	"flag"
	"io"
	"net"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

const maxFrame = 65536

func main() {
	mac := flag.String("owner-mac", "", "exact owned guest MAC")
	guestInterface := flag.Bool("guest-interface",false,"listen on the owned guest's existing en0 address")
	flag.Parse()
	model,err:=exec.Command("/usr/sbin/sysctl","-n","hw.model").Output()
	if err!=nil || !strings.HasPrefix(strings.TrimSpace(string(model)),"VirtualMac") { os.Exit(64) }
	if !regexp.MustCompile(`^([0-9a-f]{2}:){5}[0-9a-f]{2}$`).MatchString(*mac) { os.Exit(64) }
	iface,err:=net.InterfaceByName("en0");if err!=nil || iface.HardwareAddr.String()!=*mac { os.Exit(64) }
	bind := net.IPv4(127,0,0,1)
	if *guestInterface {
		addresses,err:=iface.Addrs();if err!=nil { os.Exit(64) };bind=nil
		for _,addr:=range addresses { ip,_,err:=net.ParseCIDR(addr.String());if err==nil && ip.To4()!=nil && ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast(){ bind=ip;break } }
		if bind==nil { os.Exit(64) }
	}
	listener, err := net.Listen("tcp4", net.JoinHostPort(bind.String(),"4443"))
	if err != nil { os.Exit(65) }
	defer listener.Close()
	var output sync.Mutex
	write := func(kind byte, id uint32, data []byte) error {
		if len(data) > maxFrame { return io.ErrShortBuffer }
		output.Lock(); defer output.Unlock()
		header := make([]byte, 9); header[0] = kind
		binary.BigEndian.PutUint32(header[1:5], id)
		binary.BigEndian.PutUint32(header[5:9], uint32(len(data)))
		if _, err := os.Stdout.Write(header); err != nil { return err }
		_, err := os.Stdout.Write(data); return err
	}
	var mutex sync.Mutex
	clients := make(map[uint32]net.Conn)
	closeClient := func(id uint32) {
		mutex.Lock(); client := clients[id]; delete(clients, id); mutex.Unlock()
		if client != nil { client.Close() }
	}
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		for {
			var header [9]byte
			if _, err := io.ReadFull(os.Stdin, header[:]); err != nil { return }
			kind, id, size := header[0], binary.BigEndian.Uint32(header[1:5]), binary.BigEndian.Uint32(header[5:9])
			if id == 0 || size > maxFrame || (kind != 2 && kind != 3) || (kind == 3 && size != 0) { return }
			data := make([]byte, size)
			if _, err := io.ReadFull(os.Stdin, data); err != nil { return }
			mutex.Lock(); client := clients[id]; mutex.Unlock()
			if client == nil { continue }
			if kind == 3 { closeClient(id); continue }
			client.SetWriteDeadline(time.Now().Add(20 * time.Second))
			if _, err := client.Write(data); err != nil { closeClient(id); _ = write(3, id, nil) }
		}
	}()
	if write(4, 0, nil) != nil { return }
	go func() {
		var next uint32
		for {
			client, err := listener.Accept()
			if err != nil { return }
			peer := client.RemoteAddr().(*net.TCPAddr)
			mutex.Lock()
			if len(clients) >= 8 || next >= 1000000 || (!peer.IP.IsLoopback() && !peer.IP.Equal(bind)) {
				mutex.Unlock(); client.Close(); continue
			}
			next++; id := next; clients[id] = client; mutex.Unlock()
			if write(1, id, nil) != nil { closeClient(id); return }
			go func() {
				defer closeClient(id)
				data := make([]byte, maxFrame)
				for {
					client.SetReadDeadline(time.Now().Add(5 * time.Minute))
					count, err := client.Read(data)
					if count > 0 && write(2, id, data[:count]) != nil { return }
					if err != nil { _ = write(3, id, nil); return }
				}
			}()
		}
	}()
	select { case <-finished: case <-time.After(3 * time.Hour): }
	mutex.Lock(); defer mutex.Unlock()
	for _, client := range clients { client.Close() }
}
