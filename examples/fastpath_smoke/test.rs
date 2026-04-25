use anyhow::Result;
use path_dep::meaning;

#[test]
fn fastpath_resolver_smoke() -> Result<()> {
    assert_eq!(meaning(), 42);
    Ok(())
}
