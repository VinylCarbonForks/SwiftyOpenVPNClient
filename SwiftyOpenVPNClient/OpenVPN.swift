//
//  OpenVPN.swift
//  Moonbounce
//
//  Created by Adelita Schule on 11/7/16.
//  Copyright © 2016 operatorfoundation.org. All rights reserved.
//

import Cocoa
import ServiceManagement
import SecurityFoundation

public let kOutputTextNotification = "OutputFromBashNotification"
public let outputStringKey = "outputString"

public class OpenVPN: NSObject
{
    static var connectTask:Process!
    
    /*Output Verbosity: Level 3 is recommended if you want a good summary of  what's
    happening without being swamped by output.
    
    0 -- No output except fatal errors.
    1 to 4 -- Normal usage range.
    5  -- Output R and W characters to the console for each packet read and write,
    uppercase is used for TCP/UDP packets and lowercase is used for TUN/TAP  pack-
    ets.
    6  to  11  --  Debug  info range (see errlevel.h for additional information on
    debug levels).*/
    public var verbosity = 3
    public var configFileName = "config.ovpn"
    public var outputPipe:Pipe?
    
    private var pathToOpenVPNExecutable:String
    private var directory:String = ""
    
    public init(pathToOVPNExecutable: String)
    {
        self.pathToOpenVPNExecutable = pathToOVPNExecutable
        
        super.init()
        
        ///Blah blah make or get Application Support Directory
        if let directoryURL = getApplicationDirectory()
        {
            self.directory = directoryURL.path
        }
        
        //Add listerner for app termination so that openVPN connection can be killed
        NotificationCenter.default.addObserver(forName: Notification.Name.NSApplicationWillTerminate, object: nil, queue: nil, using:
            {
                notification in
                self.stop(completion:
                    {
                        (connectionStopped) in
                        
                        if connectionStopped == false
                        {
                            print("Attempted to kill OpenVPN process on program exit and failed.")
                        }
                        else
                        {
                            print("Killed OpenVPN process for program exit.")
                        }
                })
                
        })
    }
    
    //SMJobBless:  Apple's recommended way of running privileged helper
    func blessHelper(label:String) -> Bool
    {
        var result = false
        
        // Obtain an Authorization Reference
        // You can do this at the beginning of the app. It has no extra rights until later
        var authRef: AuthorizationRef? = nil
        
        let status = AuthorizationCreate(nil, nil, [], &authRef)
        
        // There's really no reason for this to fail, but let's be careful
        guard status == errAuthorizationSuccess
        else
        {
            fatalError("Cannot create AuthorizationRef: \(status)")
        }
        
        //Ask user for admin privilege
        var authItem = AuthorizationItem(name: kSMRightBlessPrivilegedHelper, valueLength: 0, value: nil, flags: 0)
        var authRights = AuthorizationRights(count: 1, items: &authItem)
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
    
        /* Obtain the right to install our privileged helper tool (kSMRightBlessPrivilegedHelper). */
        let status2: OSStatus = AuthorizationCopyRights(authRef!, &authRights, nil, flags, nil)
        if status2 != errAuthorizationSuccess
        {
            //TODO: Unable to obtain admin privilege handle error
            print("UNABLE TO OBTAIN ADMIN PRIVILEGE")
        }
        else
        {
            /* This does all the work of verifying the helper tool against the application
             * and vice-versa. Once verification has passed, the embedded launchd.plist
             * is extracted and placed in /Library/LaunchDaemons and then loaded. The
             * executable is placed in /Library/PrivilegedHelperTools.
             */
            
            //TODO: This label must be globally unique and matches the product name of your helper
            //This also *should* not fail
            let label = "org.OperatorFoundation.MoonbounceHelper"
            var error: Unmanaged<CFError>?
            
            //Run the privileged helper
            result = SMJobBless(kSMDomainSystemLaunchd, label as CFString, authRef!, &error)
                
            if !result
            {
                print("Elevating privileges failed: \(error.debugDescription)")
            }

        }
        
        // 4. Release the Authorization Reference
        AuthorizationFree(authRef!, [])
        return result
    }

    
    func getApplicationDirectory() -> (URL)?
    {
        if let bundleID: String = Bundle.main.bundleIdentifier
        {
            let fileManager = FileManager.default
            
            // Find the application support directory in the home directory.
            let appSupportDirectory = fileManager.urls(for: FileManager.SearchPathDirectory.applicationSupportDirectory, in: FileManager.SearchPathDomainMask.userDomainMask)
            if appSupportDirectory.count > 0
            {
                // Append the bundle ID to the URL for the
                // Application Support directory
                let directoryPath = appSupportDirectory[0].appendingPathComponent(bundleID)
                
                // If the directory does not exist, this method creates it.
                // This method is only available in OS X v10.7 and iOS 5.0 or later.
                
                do
                {
                    try fileManager.createDirectory(at: directoryPath, withIntermediateDirectories: true, attributes: nil)
                }
                catch let theError
                {
                    // Handle the error.
                    print(theError)
                    return nil;
                }
                
                return directoryPath
            }
        }
        
        return nil
    }
    
    public func start(completion:@escaping (_ launched:Bool) -> Void)
    {
        
        //Path to script file
        guard let path = Bundle.main.path(forResource: "openvpn", ofType: nil)
            else
        {
            print("Unable to locate openVPN program")
            return
        }
        
        //Arguments
        let arguments = connectToOpenVPNArguments()
        
        runScript(path, arguments: arguments)
        { (wasLaunched) in
            completion(wasLaunched)
        }
    }
    
    public func stop(completion:(_ stopped:Bool) -> Void)
    {
        if OpenVPN.connectTask != nil
        {
            OpenVPN.connectTask!.terminate()
        }
        
        completion(!OpenVPN.connectTask.isRunning)
    }
    
    private func connectToOpenVPNArguments() -> [String]
    {
        //List of arguments for Process/Task
        var processArguments: [String] = []
        
        //processArguments.append("--daemon")
        processArguments.append("--cd")
        processArguments.append(directory)
        processArguments.append("--verb")
        processArguments.append(String(verbosity))
        processArguments.append("--config")
        processArguments.append(configFileName)
        processArguments.append("--verb")
        processArguments.append(String(verbosity))
        processArguments.append("--cd")
        processArguments.append(directory)
        processArguments.append("--management")
        processArguments.append("127.0.0.1")
        processArguments.append("1337")
        processArguments.append("--management-query-passwords")
        //processArguments.append("--management-hold")
        
        return processArguments
    }
    
    private func runScript(_ path: String, arguments: [String], completion:@escaping (_ launched: Bool) -> Void)
    {
        //Run heavy lifting on the background thread.
        let taskQueue = DispatchQueue.global(qos: DispatchQoS.QoSClass.background)
        taskQueue.async
            {
                //Creates a new Process and assigns it to the connectTask property.
                OpenVPN.connectTask = Process()
                //The launchPath is the path to the executable to run.
                OpenVPN.connectTask.launchPath = path
                //Arguments will pass the arguments to the executable, as though typed directly into terminal.
                OpenVPN.connectTask.arguments = arguments
                
                //Do something after the process (FKA NSTask) is finished
                OpenVPN.connectTask.terminationHandler =
                    {
                        task in
                        
                        //TODO: Give actual results one day
                        completion(true)
                }
                
                self.addOutputObserver()
                
                //Go ahead and launch the process/task
                OpenVPN.connectTask.launch()
                
                //Block any other activity on this thread until the process/task is finished
                OpenVPN.connectTask.waitUntilExit()
                
                if !OpenVPN.connectTask.isRunning
                {
                    let status = OpenVPN.connectTask.terminationStatus
                    
                    //TODO: You’ll need to look at the documentation for that task to learn what values it returns under what circumstances.
                    if status == 0 {
                        print("Task succeeded.")
                    } else {
                        print("Task failed.")
                    }
                }
        }
    }
    
    //Dev purposes - Show output from command line task
    func addOutputObserver()
    {
        outputPipe = Pipe()
        OpenVPN.connectTask.standardOutput = outputPipe
        outputPipe!.fileHandleForReading.waitForDataInBackgroundAndNotify()
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSFileHandleDataAvailable, object: outputPipe!.fileHandleForReading, queue: nil, using:
            {
                notification in
                
                let output = self.outputPipe!.fileHandleForReading.availableData
                let outputString = String(data: output, encoding: String.Encoding.utf8) ?? ""
                
                DispatchQueue.main.async(execute:
                    {
                        //Notify any observers that a new string is available
                        NotificationCenter.default.post(name: Notification.Name(rawValue: kOutputTextNotification), object: nil, userInfo: [outputStringKey: outputString])
                })
                
                self.outputPipe!.fileHandleForReading.waitForDataInBackgroundAndNotify()
        })
    }

/*🌙*/
}
