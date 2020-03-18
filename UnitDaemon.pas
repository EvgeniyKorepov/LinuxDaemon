unit UnitDaemon;

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.SyncObjs,
  Posix.Stdlib,
  Posix.SysStat,
  Posix.SysTypes,
  Posix.Unistd,
  Posix.Signal,
  Posix.Fcntl,
  Posix.Syslog;

const
  // Missing from linux/StdlibTypes.inc !!! <stdlib.h>
  EXIT_FAILURE = 1;
  EXIT_SUCCESS = 0;

type

  TEventType = (
    Start,
    Stop,
    StopProcess,
    Reload
  );

  TQueueEvent = TThreadedQueue<TEventType>;

  TDaemon = class(TThread)
  private
    FPIDFilePath : String;
    FPID: pid_t;
    FSID: pid_t;
    FFID: Integer;
    FQueueEvent : TQueueEvent;
    FQueueSignals : TThreadedQueue<Integer>;
    function WritePIDFile() : boolean;
    function DeletePIDFile() : boolean;
    function Start() : Boolean;
    function WaitPIPFile() : boolean;
  protected
    procedure Execute; override;
  public
    constructor Create();
    destructor Destroy; override;
  end;

var
  Daemon : TDaemon;
  QueueEvent : TQueueEvent;

implementation

var
  QueueSignals : TThreadedQueue<Integer>;

// 1. If SIGTERM is received, shut down the daemon and exit cleanly.
// 2. If SIGHUP is received, reload the configuration files, if this applies.
procedure HandleSignals(SigNum: Integer); cdecl;
var ASigNum : Integer;
begin
  if Assigned(QueueSignals) then
  begin
    ASigNum := SigNum;
    QueueSignals.PushItem(ASigNum);
  end;
end;

constructor TDaemon.Create();
begin
  FQueueSignals := QueueSignals;
  FQueueEvent := QueueEvent;

  FPIDFilePath := '/run/' + TPath.ChangeExtension(TPath.GetFileName(ParamStr(0)), '.pid');

  // syslog() will call openlog() with no arguments if the log is not currently open.
  openlog(nil, LOG_PID or LOG_NDELAY, LOG_DAEMON);
  syslog(LOG_NOTICE, '------------------------------------------------------------------');
  syslog(LOG_NOTICE, 'Daemon.Create()');

  if not Start() then
    inherited Create(True)
  else
    inherited Create(False);
end;

destructor TDaemon.Destroy;
begin
  DeletePIDFile();
  syslog(LOG_NOTICE, 'Daemon.Destroy()');
  closelog();
  inherited Destroy;
end;

procedure TDaemon.Execute;
var AQueueSize : Integer;
    ASignalNum : Integer;
begin
  while Not Terminated do
  begin
    ASignalNum := 0;
    if QueueSignals.PopItem(AQueueSize, ASignalNum) = System.SyncObjs.TWaitResult.wrSignaled then
    begin
      case ASignalNum of
        SIGINT :
        begin
          syslog(LOG_NOTICE, 'Daemon receive signal SIGINT');
        end;
        SIGHUP :
        begin
          FQueueEvent.PushItem(TEventType.Reload);
          // Reload config
          syslog(LOG_NOTICE, 'Daemon receive signal SIGHUP');
        end;
        SIGTERM :
        begin
          FQueueEvent.PushItem(TEventType.Stop);
          syslog(LOG_NOTICE, 'Daemon receive signal SIGTERM');
        end;
        SIGQUIT :
        begin
          FQueueEvent.PushItem(TEventType.Stop);
          syslog(LOG_NOTICE, 'Daemon receive signal SIGQUIT');
        end;
      end;
    end;
    TThread.Sleep(5);
  end;
end;

function TDaemon.Start() : Boolean;
var AIndex: Integer;
begin
  Result := False;

  FPID := fork();

  if FPID < 0 then
  begin
    syslog(LOG_ERR, 'Error forking the process');
    Halt(EXIT_FAILURE);
  end;

  if FPID > 0 then
    // Wait for Daemon create PID file (systemd should see the PID file when the main thread completes)
    if WaitPIPFile() then
      Halt(EXIT_SUCCESS)
    else
      Halt(EXIT_FAILURE);

  syslog(LOG_NOTICE, 'the parent is killed!');

  // This call will place the server in a new process group and session and
  // detaches its controlling terminal
  FSID := setsid();
  if FSID < 0 then
  begin
//    raise Exception.Create('Impossible to create an independent session');
    syslog(LOG_ERR, 'Impossible to create an independent session');
    Halt(EXIT_FAILURE);
  end;

  syslog(LOG_NOTICE, 'session created and process group ID set');

  // Catch, ignore and handle signals
  signal(SIGCHLD, TSignalHandler(SIG_IGN));
  signal(SIGINT,  HandleSignals);
  signal(SIGHUP,  HandleSignals);
  signal(SIGTERM, HandleSignals);
  signal(SIGQUIT, HandleSignals);
//  FAction._u.sa_handler := HandleSignals;

  syslog(LOG_NOTICE, 'before 2nd fork() - child process');

  // Call fork() again, to be sure daemon can never re-acquire the terminal
  FPID := fork();

  syslog(LOG_NOTICE, 'after 2nd fork() - the grandchild is born');

  if FPID < 0 then
  begin
    //raise Exception.Create('Error forking the process');
    syslog(LOG_ERR, 'Error forking the process');
    Halt(EXIT_FAILURE);
  end;

  // Call exit() in the first child, so that only the second child
  // (the actual daemon process) stays around. This ensures that the daemon
  // process is re-parented to init/PID 1, as all daemons should be.
  if FPID > 0 then
    Halt(EXIT_SUCCESS);
  syslog(LOG_NOTICE, 'the 1st child is killed!');

  // Open descriptors are inherited to child process, this may cause the use
  // of resources unneccessarily. Unneccesarry descriptors should be closed
  // before fork() system call (so that they are not inherited) or close
  // all open descriptors as soon as the child process starts running

  // Close all opened file descriptors (stdin, stdout and stderr)
  for AIndex := sysconf(_SC_OPEN_MAX) downto 0 do
    __close(AIndex);

  syslog(LOG_NOTICE, 'file descriptors closed');

  // Route I/O connections to > dev/null
  // Open STDIN
  FFID := __open('/dev/null', O_RDWR);
  // Dup STDOUT
  dup(FFID);
  // Dup STDERR
  dup(FFID);

  syslog(LOG_NOTICE, 'stdin, stdout, stderr redirected to /dev/null');

  // if you don't redirect the stdout the program hangs
//  Writeln('Test writeln');
//  syslog(LOG_NOTICE, 'if you see this message the daemon isn''t crashed writing on stdout!');

  // Set new file permissions:
  // most servers runs as super-user, for security reasons they should
  // protect files that they create, with unmask the mode passes to open(), mkdir()

  // Restrict file creation mode to 750
	umask(027);

  syslog(LOG_NOTICE, 'file permission changed to 750');

  // The current working directory should be changed to the root directory (/), in
  // order to avoid that the daemon involuntarily blocks mount points from being unmounted
  chdir('/');
  syslog(LOG_NOTICE, 'changed directory to "/"');

  // TODO: write the daemon PID (as returned by getpid()) to a PID file, for
  // example /run/delphid.pid to ensure that the daemon cannot be started more than once

  FPID := getpid();
//  syslog(LOG_NOTICE, 'daemon pid : ' + FPID.ToString);
  WritePIDFile();
  syslog(LOG_NOTICE, 'daemon started');
//  FIsDaemon := True;
  FQueueEvent.PushItem(TEventType.Start);
  Result := True;
end;

function TDaemon.WritePIDFile() : boolean;
begin
  Result := False;
  try
    if DeletePIDFile() then
      TFile.WriteAllText(FPIDFilePath, FPID.ToString + #10);
  except
    on E : Exception do
    begin
      syslog(LOG_ERR, 'daemon: error create pid file : ' + E.Message);
      exit;
    end;
  end;
  syslog(LOG_NOTICE, 'daemon: succseful write pid file');
  Result := True;
end;

function TDaemon.DeletePIDFile() : boolean;
begin
  Result := False;
  try
    if TFile.Exists(FPIDFilePath) then
    begin
      TFile.Delete(FPIDFilePath);
      syslog(LOG_NOTICE, 'daemon: succseful delete pid file');
    end;
  except
    on E : Exception do
    begin
      syslog(LOG_ERR, 'daemon: error delete pid file : ' + E.Message);
      exit;
    end;
   end;
  Result := True;
end;

function TDaemon.WaitPIPFile() : boolean;
const
  ConstWaitTimeMs = 10000;
  ConstCheckIntervalMs = 200;
var ACounter : Integer;
begin
  Result := False;
  ACounter := 0;
  while not TFile.Exists(FPIDFilePath) do
  begin
    if ACounter >= ConstWaitTimeMs then
      exit;
    Sleep(ConstCheckIntervalMs);
    Inc(ACounter, ConstCheckIntervalMs);
  end;
  Result := true;
end;

initialization

  QueueSignals := TThreadedQueue<Integer>.Create(10,1000, 100);
  QueueEvent := TQueueEvent.Create(10,1000, 100);
//  Daemon := TDaemon.Create(QueueSignals, QueueEvent);

finalization

  if Assigned(Daemon) then
  begin
    Daemon.Terminate;
    Daemon.WaitFor;
    Daemon.Free;
  end;
  if Assigned(QueueEvent) then
    QueueEvent.Free;
  if Assigned(QueueSignals) then
    QueueSignals.Free;

end.
