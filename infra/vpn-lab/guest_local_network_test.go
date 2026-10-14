package main

import (
 "encoding/binary"
 "testing"
)

func question(name string,kind uint16) []byte {
 q:=[]byte{0x12,0x34,1,0,0,1,0,0,0,0,0,0}
 label:=""
 for _,char:=range name+"." { if char=='.' { q=append(q,byte(len(label)));q=append(q,[]byte(label)...);label="" } else { label+=string(char) } }
 q=append(q,0,byte(kind>>8),byte(kind),0,1)
 return q
}

func TestOnlyOwnedEndpointsResolve(t *testing.T) {
 for _,name:=range []string{"vpn-lab.invalid","captive.apple.com","VPN-LAB.INVALID"} {
  q:=question(name,1);a:=reply(q)
  if len(a)!=len(q)+16 || binary.BigEndian.Uint16(a[6:8])!=1 || string(a[len(a)-4:])!=string([]byte{127,0,0,1}) { t.Fatal("owned endpoint failed") }
 }
 for _,name:=range []string{"vpn.x5.ru","example.com","captive.apple.com.attacker.invalid","vpn-lab.invalid.attacker.invalid"} {
  a:=reply(question(name,1));if a[3]&15!=3 || binary.BigEndian.Uint16(a[6:8])!=0 { t.Fatal("external endpoint was resolved") }
 }
 a:=reply(question("vpn-lab.invalid",28));if a[3]&15!=0 || binary.BigEndian.Uint16(a[6:8])!=0 { t.Fatal("IPv6 must never add an external route") }
}

func TestMalformedPacketRejectedBeforeResponse(t *testing.T) {
 valid:=question("vpn-lab.invalid",1)
 for _,packet:=range [][]byte{nil,valid[:17],make([]byte,513),append([]byte(nil),valid...)} {
  if len(packet)==len(valid) { packet[12]=0xc0 }
  if reply(packet)!=nil { t.Fatal("malformed DNS response was accepted") }
 }
 for _,offset:=range []int{2,4,5} {
  q:=append([]byte(nil),valid...);if offset==2 { q[offset]|=0x80 } else { q[offset]=2 }
  if reply(q)!=nil { t.Fatal("non-query or multi-question packet was accepted") }
 }
}

func TestOwnedInterfaceAddressOnlyChangesVPNAnswer(t *testing.T) {
 old:=vpnTargetIPv4;defer func(){ vpnTargetIPv4=old }()
 vpnTargetIPv4=[]byte{192,168,128,2}
 a:=reply(question("vpn-lab.invalid",1));if string(a[len(a)-4:])!=string(vpnTargetIPv4){ t.Fatal("owned guest interface did not resolve") }
 a=reply(question("captive.apple.com",1));if string(a[len(a)-4:])!=string([]byte{127,0,0,1}){ t.Fatal("connectivity endpoint must stay loopback") }
 a=reply(question("example.com",1));if a[3]&15!=3 { t.Fatal("external DNS must remain denied") }
}
