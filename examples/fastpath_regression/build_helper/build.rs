use std::fs;

fn main() {
    println!("cargo:rerun-if-changed=data/message.txt");

    let message = fs::read_to_string("data/message.txt")
        .expect("build helper data should be available to the build script");

    println!("cargo:rustc-env=BUILD_HELPER_MESSAGE={}", message.trim());
}
