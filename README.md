# LinuxDaemon
Linux Daemon

See also Linux Daemon new style https://github.com/EvgeniyKorepov/LinuxDaemonNewStyle

Example :

```
program DaemonTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  System.SyncObjs,
  Posix.Stdlib,
  Posix.SysStat,
  Posix.SysTypes,
  Posix.Unistd,
  Posix.Signal,
  Posix.Fcntl,
  Posix.Syslog in 'Posix.Syslog.pas',
  UnitDaemon in 'UnitDaemon.pas';

var
  AEventType : TEventType;

begin
  syslog(LOG_NOTICE, 'main START');
  while True do
  begin
    syslog(LOG_NOTICE, 'main LOOP');
    if UnitDaemon.QueueEvent.PopItem(AEventType) = System.SyncObjs.TWaitResult.wrSignaled then
    begin
      syslog(LOG_NOTICE, 'main UnitDaemon.QueueEvent.PopItem');
      case AEventType of
        TEventType.StopProcess :
        begin
          syslog(LOG_NOTICE, 'main Event StopProcess');
          ExitCode := EXIT_SUCCESS;
          exit;
        end;
        TEventType.Start :
        begin
          syslog(LOG_NOTICE, 'main Event START');
        end;
        TEventType.Reload :
        begin
          // Reload config
          syslog(LOG_NOTICE, 'main Event RELOAD');
        end;
        TEventType.Stop :
        begin
          syslog(LOG_NOTICE, 'main Event STOP');
          ExitCode := EXIT_SUCCESS;
          exit;
        end;
      end;
    end;
    Sleep(50);
  end;
end.
```

Place DaemonTest.service to /etc/systemd/system/ and use :
```
systemctl start DaemonTest.service
systemctl reload DaemonTest.service
systemctl stop DaemonTest.service
```
