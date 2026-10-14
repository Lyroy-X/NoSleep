import CryptoKit
import Darwin
import Foundation
import IOKit
import SystemConfiguration

func actualCFBoolean(_ value:Any?)->Bool? {
    guard let value, CFGetTypeID(value as CFTypeRef)==CFBooleanGetTypeID() else {return nil}
    return (value as? NSNumber)?.boolValue
}
func offlineQualified(linkReadable:Bool, en0Active:Bool?, physicalActive:Bool, administrativeDown:Bool)->Bool {
    linkReadable && en0Active == false && !physicalActive && administrativeDown
}
if CommandLine.arguments==[CommandLine.arguments[0],"--pure-contracts"] {
    precondition(offlineQualified(linkReadable:true,en0Active:false,physicalActive:false,administrativeDown:true))
    precondition(!offlineQualified(linkReadable:true,en0Active:true,physicalActive:true,administrativeDown:true))
    precondition(!offlineQualified(linkReadable:false,en0Active:nil,physicalActive:false,administrativeDown:true))
    precondition(!offlineQualified(linkReadable:true,en0Active:false,physicalActive:true,administrativeDown:true))
    precondition(!offlineQualified(linkReadable:true,en0Active:false,physicalActive:false,administrativeDown:false))
    precondition(actualCFBoolean(kCFBooleanFalse)==false);precondition(actualCFBoolean(kCFBooleanTrue)==true)
    precondition(actualCFBoolean(NSNumber(value:0))==nil);precondition(actualCFBoolean(NSNumber(value:1))==nil)
    precondition(actualCFBoolean("false")==nil)
    print("{\"pureCases\":10,\"runtimeCalls\":0}");exit(0)
}
func require(_ yes:Bool) {if !yes {print("{\"snapshotRefused\":true,\"mutations\":0}");exit(70)}}
require(CommandLine.arguments==[CommandLine.arguments[0],"--owned-guest-readonly-snapshot"] && getuid()==501)
guard let account=getpwuid(501) else {exit(70)};require(String(cString:account.pointee.pw_name)=="admin")
var console=stat();require(stat("/dev/console",&console)==0 && console.st_uid==501)
var size=0;require(sysctlbyname("hw.model",nil,&size,nil,0)==0 && size>0 && size<256)
var model=[CChar](repeating:0,count:size);require(sysctlbyname("hw.model",&model,&size,nil,0)==0 && String(cString:model).hasPrefix("VirtualMac"))
let all=SCNetworkInterfaceCopyAll() as? [SCNetworkInterface];require(all != nil)
guard let store=SCDynamicStoreCreate(nil,"Owned physical link readonly" as CFString,nil,nil) else {exit(70)}
var links=[[String:Any]]();var en0Found=false,en0Readable=false;var en0Active:Bool?;var physical=false
for interface in all! {
    guard let type=SCNetworkInterfaceGetInterfaceType(interface),type==kSCNetworkInterfaceTypeEthernet || type==kSCNetworkInterfaceTypeIEEE80211,
          let name=SCNetworkInterfaceGetBSDName(interface) as String? else {continue}
    let link=SCDynamicStoreCopyValue(store,"State:/Network/Interface/\(name)/Link" as CFString) as? [String:Any]
    let sourceActive=link?["Active"] as? Bool;if sourceActive==true {physical=true}
    let active=actualCFBoolean(link?["Active"])
    links.append(["interface":name,"type":type==kSCNetworkInterfaceTypeEthernet ? "Ethernet":"WiFi","activeReadable":active != nil,"active":active as Any? ?? NSNull()])
    if name=="en0" {require(!en0Found);en0Found=true;en0Active=active;en0Readable=active != nil
        require(type==kSCNetworkInterfaceTypeEthernet && (SCNetworkInterfaceGetHardwareAddressString(interface) as String?)?.lowercased()=="42:35:8c:14:fd:0c")}
}
require(en0Found)
var addresses:UnsafeMutablePointer<ifaddrs>?;require(getifaddrs(&addresses)==0);defer {freeifaddrs(addresses)}
var entry=addresses;var flags:UInt32?;var ipv4=[String]()
while let current=entry {
    let value=current.pointee;entry=value.ifa_next
    guard String(cString:value.ifa_name)=="en0" else {continue}
    if let flags {require(flags==value.ifa_flags)} else {flags=value.ifa_flags}
    if let address=value.ifa_addr,address.pointee.sa_family==AF_INET {
        var host=[CChar](repeating:0,count:Int(NI_MAXHOST))
        require(getnameinfo(address,socklen_t(address.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST)==0)
        ipv4.append(String(cString:host))
    }
}
require(flags != nil)
guard let prefs=SCPreferencesCreate(nil,"Owned service identity readonly" as CFString,nil),let services=SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {exit(70)}
let serviceIDs=services.compactMap {service->String? in
    guard let interface=SCNetworkServiceGetInterface(service),(SCNetworkInterfaceGetBSDName(interface) as String?)=="en0" else {return nil}
    return SCNetworkServiceGetServiceID(service) as String?
}.sorted()
require(serviceIDs.count==1)
let up=(flags! & UInt32(IFF_UP)) != 0
let powerRoot=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain"))
var sleep:Bool?
if powerRoot != 0 {
    sleep=(IORegistryEntryCreateCFProperty(powerRoot,"SleepDisabled" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? NSNumber)?.boolValue
    IOObjectRelease(powerRoot)
}
let value:[String:Any]=["schema":1,"UID501VirtualMACConsole":true,"interface":"en0","flags":flags!,"administrativeUp":up,"IPv4":ipv4.sorted(),"serviceIDs":serviceIDs,"linkActiveReadable":en0Readable,"en0Active":en0Active as Any? ?? NSNull(),"physicalNetworkLikeProduction":physical,"physicalLinks":links,"offlineQualified":offlineQualified(linkReadable:en0Readable,en0Active:en0Active,physicalActive:physical,administrativeDown:!up),"sleepDisabledReadable":sleep != nil,"sleepDisabled":sleep as Any? ?? NSNull(),"mutations":0]
let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);print(String(decoding:data,as:UTF8.self))
