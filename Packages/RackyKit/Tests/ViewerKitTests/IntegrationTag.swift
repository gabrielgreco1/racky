import Testing

extension Tag {
    /// Suítes pesadas: `rackyd` real, zsh, Docker, LaunchAgent. `scripts/test.sh` as roda em série, depois do resto.
    @Tag static var integration: Tag
}
