use anyhow::Result;
use local_macro::answer;

#[test]
fn fastpath_regression() -> Result<()> {
    assert_eq!(answer!(), 42);
    assert_eq!(build_helper::message(), "hello from build script");
    assert_eq!(git_message::message(), "hello from git dependency");
    assert_eq!(override_dep::message(), "hello from override target");
    Ok(())
}
