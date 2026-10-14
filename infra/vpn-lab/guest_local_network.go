// Local DNS/connectivity prerequisites for the disposable macOS guest only.
// Built as an owned lab helper, never installed on the working Mac.
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

var vpnTargetIPv4 = []byte{127,0,0,1}

func reply(q []byte) []byte {
	if len(q) < 17 || len(q) > 512 || q[2]&0xf8 != 0 || binary.BigEndian.Uint16(q[4:6]) != 1 {
		return nil
	}
	offset := 12
	var names []string
	for {
		if offset >= len(q) { return nil }
		n := int(q[offset]); offset++
		if n == 0 { break }
		if n > 63 || offset+n > len(q) { return nil }
		names = append(names, string(q[offset:offset+n])); offset += n
	}
	if offset+4 > len(q) || offset > 255 { return nil }
	typeID := binary.BigEndian.Uint16(q[offset:offset+2])
	classID := binary.BigEndian.Uint16(q[offset+2:offset+4])
	name := strings.ToLower(strings.Join(names, "."))
	known := name == "vpn-lab.invalid" || name == "captive.apple.com"
	answer := append([]byte(nil), q[:offset+4]...)
	answer[2] = 0x80 | (q[2] & 1); answer[3] = 0x80
	for i := 6; i < 12; i++ { answer[i] = 0 }
	if !known || classID != 1 { answer[3] |= 3; return answer }
	if typeID == 1 {
		binary.BigEndian.PutUint16(answer[6:8], 1)
		address:=[]byte{127,0,0,1};if name=="vpn-lab.invalid" { address=vpnTargetIPv4 }
		answer = append(answer, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 5, 0, 4)
		answer = append(answer,address...)
	}
	return answer
}

func main() {
	mac := flag.String("owner-mac", "", "exact MAC of the disposable guest")
	guestInterface := flag.Bool("vpn-guest-interface",false,"resolve the VPN only to the owned guest's existing en0 IPv4")
	flag.Parse()
	model, err := exec.Command("/usr/sbin/sysctl","-n","hw.model").Output()
	if err != nil || !strings.HasPrefix(strings.TrimSpace(string(model)),"VirtualMac") || os.Geteuid()!=0 { os.Exit(64) }
	if !regexp.MustCompile(`^([0-9a-f]{2}:){5}[0-9a-f]{2}$`).MatchString(*mac) { os.Exit(65) }
	iface, err := exec.Command("/sbin/ifconfig","en0").Output()
	if err!=nil || !strings.Contains(string(iface),"ether "+*mac) { os.Exit(66) }
	if *guestInterface {
		physical,err:=net.InterfaceByName("en0");if err!=nil || physical.HardwareAddr.String()!=*mac { os.Exit(66) }
		addresses,err:=physical.Addrs();if err!=nil { os.Exit(66) };found:=false
		for _,address:=range addresses { ip,_,err:=net.ParseCIDR(address.String());if err==nil && ip.To4()!=nil && ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast(){ vpnTargetIPv4=ip.To4();found=true;break } }
		if !found { os.Exit(66) }
	}
	// No flag can change the listener addresses or whitelist.
	udp, err := net.ListenPacket("udp4", "127.0.0.1:53"); if err != nil { panic("guest DNS bind failed") }
	tcp, err := net.Listen("tcp4", "127.0.0.1:53"); if err != nil { panic("guest TCP DNS bind failed") }
	httpListener, err := net.Listen("tcp4", "127.0.0.1:80"); if err != nil { panic("guest connectivity bind failed") }
	var once sync.Once
	stop := func() { once.Do(func() { udp.Close(); tcp.Close(); httpListener.Close() }) }
	defer stop()
	time.AfterFunc(3*time.Hour, func() { stop(); os.Exit(0) })
	go func() {
		buf := make([]byte, 513)
		for { n, peer, err := udp.ReadFrom(buf); if err != nil { return }; if out := reply(buf[:n]); out != nil { udp.WriteTo(out, peer) } }
	}()
	go func() {
		busy := make(chan struct{}, 16)
		for {
			conn, err := tcp.Accept(); if err != nil { return }
			select { case busy <- struct{}{}: default: conn.Close(); continue }
			go func() {
				defer conn.Close(); defer func(){ <-busy }()
				conn.SetDeadline(time.Now().Add(5*time.Second))
				var header [2]byte
				if _, err := io.ReadFull(conn, header[:]); err != nil { return }
				n := int(binary.BigEndian.Uint16(header[:])); if n > 512 { return }
				q := make([]byte,n); if _, err := io.ReadFull(conn,q); err != nil { return }
				out := reply(q); if out == nil { return }; binary.BigEndian.PutUint16(header[:],uint16(len(out)))
				conn.Write(append(header[:],out...))
			}()
		}
	}()
	server := &http.Server{ReadHeaderTimeout: 2*time.Second, ReadTimeout: 2*time.Second, WriteTimeout: 2*time.Second,
		IdleTimeout: 2*time.Second, MaxHeaderBytes: 4096, Handler: http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
			host := strings.ToLower(strings.Split(r.Host,":")[0])
			if host != "captive.apple.com" || (r.URL.Path != "/" && r.URL.Path != "/hotspot-detect.html") { http.NotFound(w,r);return }
			w.Header().Set("Content-Type","text/html")
			io.WriteString(w,"<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>")
		})}
	fmt.Fprintln(os.Stdout,"Guest-only loopback DNS and local connectivity endpoint ready.")
	server.Serve(httpListener)
}
