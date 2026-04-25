use cargo_toml::Manifest;

use std::env::args_os;
use std::path::Path;

fn escape_json(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            c if c.is_control() => escaped.push_str(&format!("\\u{:04x}", c as u32)),
            c => escaped.push(c),
        }
    }
    escaped
}

fn push_field(buf: &mut String, first: &mut bool, key: &str, value: &str) {
    if !*first {
        buf.push(',');
    }
    *first = false;
    buf.push('"');
    buf.push_str(key);
    buf.push_str("\":\"");
    buf.push_str(&escape_json(value));
    buf.push('"');
}

fn push_bool(buf: &mut String, first: &mut bool, key: &str, value: bool) {
    if !*first {
        buf.push(',');
    }
    *first = false;
    buf.push('"');
    buf.push_str(key);
    buf.push_str("\":");
    buf.push_str(if value { "true" } else { "false" });
}

fn package_json(manifest: &Manifest) -> String {
    let package = manifest
        .package
        .as_ref()
        .unwrap_or_else(|| panic!("manifest missing [package] section"));
    let mut json = String::from("{");
    let mut first = true;
    push_field(&mut json, &mut first, "name", &package.name);
    push_field(&mut json, &mut first, "version", &package.version.to_string());
    push_field(&mut json, &mut first, "edition", package.edition.as_str());
    if let Some(links) = package.links.as_ref() {
        push_field(&mut json, &mut first, "links", links);
    }
    json.push('}');
    json
}

fn lib_json(manifest: &Manifest) -> String {
    let lib = manifest.lib.as_ref();
    let mut json = String::from("{");
    let mut first = true;
    if let Some(lib) = lib {
        if let Some(name) = lib.name() {
            push_field(&mut json, &mut first, "name", name);
        }
        if let Some(path) = lib.path.as_ref() {
            push_field(&mut json, &mut first, "path", path);
        }
        push_bool(
            &mut json,
            &mut first,
            "proc_macro",
            lib.proc_macro.unwrap_or(false),
        );
    }
    json.push('}');
    json
}

fn bins_json(manifest: &Manifest) -> String {
    let mut json = String::from("[");
    for (idx, bin) in manifest.bin.iter().enumerate() {
        if idx > 0 {
            json.push(',');
        }
        let mut entry = String::from("{");
        let mut first = true;
        push_field(
            &mut entry,
            &mut first,
            "name",
            bin.name.as_deref().unwrap_or(""),
        );
        if let Some(path) = bin.path.as_ref() {
            push_field(&mut entry, &mut first, "path", path);
        }
        entry.push('}');
        json.push_str(&entry);
    }
    json.push(']');
    json
}

fn build_json(manifest: &Manifest) -> String {
    match manifest.package.as_ref().and_then(|package| package.build.as_ref()) {
        Some(build) => format!("\"{}\"", escape_json(build)),
        None => "null".to_owned(),
    }
}

fn main() {
    let args: Vec<_> = args_os().collect();
    let path = match &args[..] {
        [_, path] => Path::new(path),
        _ => panic!("usage: cargo_manifest_info path/to/Cargo.toml"),
    };

    let manifest = Manifest::from_path(path)
        .unwrap_or_else(|err| panic!("failed to parse {}: {}", path.display(), err));

    println!(
        "{{\"package\":{},\"lib\":{},\"bin\":{},\"build\":{}}}",
        package_json(&manifest),
        lib_json(&manifest),
        bins_json(&manifest),
        build_json(&manifest),
    );
}
