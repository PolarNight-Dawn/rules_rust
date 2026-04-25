use std::env::args_os;
use std::fs::read_to_string;
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

fn string_field(buf: &mut String, first: &mut bool, key: &str, value: Option<&str>) {
    if let Some(value) = value {
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
}

fn string_array(buf: &mut String, first: &mut bool, key: &str, values: &[String]) {
    if !*first {
        buf.push(',');
    }
    *first = false;
    buf.push('"');
    buf.push_str(key);
    buf.push_str("\":[");
    for (idx, value) in values.iter().enumerate() {
        if idx > 0 {
            buf.push(',');
        }
        buf.push('"');
        buf.push_str(&escape_json(value));
        buf.push('"');
    }
    buf.push(']');
}

fn table_to_json(table: &toml::value::Table) -> String {
    let mut json = String::from("{");
    let mut first = true;

    string_field(
        &mut json,
        &mut first,
        "name",
        table.get("name").and_then(toml::Value::as_str),
    );
    string_field(
        &mut json,
        &mut first,
        "version",
        table.get("version").and_then(toml::Value::as_str),
    );
    string_field(
        &mut json,
        &mut first,
        "source",
        table.get("source").and_then(toml::Value::as_str),
    );
    string_field(
        &mut json,
        &mut first,
        "checksum",
        table.get("checksum").and_then(toml::Value::as_str),
    );

    let dependencies = table
        .get("dependencies")
        .and_then(toml::Value::as_array)
        .map(|array| {
            array
                .iter()
                .filter_map(toml::Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    string_array(&mut json, &mut first, "dependencies", &dependencies);

    json.push('}');
    json
}

fn parse_lockfile(path: &Path) -> String {
    let content = read_to_string(path)
        .unwrap_or_else(|err| panic!("failed to read {}: {}", path.display(), err));
    let root: toml::Value = toml::from_str(&content)
        .unwrap_or_else(|err| panic!("failed to parse {}: {}", path.display(), err));
    let packages = root
        .get("package")
        .and_then(toml::Value::as_array)
        .unwrap_or_else(|| panic!("{} does not contain [[package]] entries", path.display()));

    let mut json = String::from("{\"package\":[");
    for (idx, package) in packages.iter().enumerate() {
        if idx > 0 {
            json.push(',');
        }
        let table = package
            .as_table()
            .unwrap_or_else(|| panic!("package entry {} is not a table", idx));
        json.push_str(&table_to_json(table));
    }
    json.push_str("]}");
    json
}

fn main() {
    let args: Vec<_> = args_os().collect();
    let path = match &args[..] {
        [_, path] => Path::new(path),
        _ => panic!(
            "usage: cargo_lock_info path/to/Cargo.lock"
        ),
    };

    println!("{}", parse_lockfile(path));
}
