//! The three original macOS PlatformTests child-process assertions.
#![cfg(target_os = "macos")]
use rbn_core::process::{self,Context};
use std::{collections::BTreeMap,process::Stdio,time::{Duration,Instant}};
fn context()->Context{Context{binary:"/bin/sh".into(),arguments:vec![],environment:BTreeMap::from([("PATH".into(),"/usr/bin:/bin:/usr/sbin:/sbin".into()),("RBN_TEST_VALUE".into(),"environment".into())]),work_dir:std::env::temp_dir()}}
#[test]
fn mac_child_arguments_preserve_composed_decomposed_unicode_byte_for_byte(){
    let values=["が","か\u{3099}","é","e\u{301}","引用‛？／","","a b","\"'$`\\"];
    let mut args=vec!["-c".into(),"printf '%s\\0' \"$@\"".into(),"fixture".into()];args.extend(values.map(str::to_owned));
    let actual=process::capture(&context(),&args,65536,Duration::from_secs(10),None).unwrap();
    let mut expected=vec![];for value in values{expected.extend_from_slice(value.as_bytes());expected.push(0);}
    assert_eq!(actual.exit_code,0);assert_eq!(actual.stdout,expected);
}
#[test]
fn mac_unicode_launch_retains_streams_environment_and_exit_status(){
    let args=["-c","IFS= read -r value; printf '%s:%s' \"$value\" \"$RBN_TEST_VALUE\"; printf error >&2; exit 37","が"].map(str::to_owned);
    let actual=process::capture_input(&context(),&args,b"input\n",65536,Duration::from_secs(10),None).unwrap();
    assert_eq!(actual.stdout,b"input:environment");assert_eq!(actual.stderr,b"error");assert_eq!(actual.exit_code,37);
}
#[test]
fn mac_unicode_launch_cancellation_reaches_tracked_child_pid(){
    use std::os::unix::process::ExitStatusExt;
    let mut command=process::command(&context()).unwrap();command.args(["-c","exec /bin/sleep 20","が"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    let mut child=command.spawn().unwrap();std::thread::sleep(Duration::from_millis(100));let began=Instant::now();assert_eq!(process::signal(child.id(),libc::SIGTERM),0);let status=child.wait().unwrap();assert!(began.elapsed()<Duration::from_secs(2));assert_eq!(status.signal(),Some(libc::SIGTERM));
}
