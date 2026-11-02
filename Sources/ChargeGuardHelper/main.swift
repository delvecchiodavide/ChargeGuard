// ChargeGuardHelper — privileged launchd daemon.
//
// Registered by the app with SMAppService.daemon(plistName:). launchd starts it
// as root on demand when the app connects to the Mach service
// "com.example.chargeguard.helper"; it is the only process that writes to the SMC.
import Foundation

let service = HelperService()
service.start()
dispatchMain()
