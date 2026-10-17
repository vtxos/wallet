# Repository Guidelines

## Project Structure & Module Organization
- `app/` Flutter app (`app/lib/screens`, `app/lib/services/mpc_service.dart`, `app/lib/passkey/`).
- `core/` Dart wallet core: `client.dart` (`MpcClient`), `sessions/` (one driver per ceremony
  stream), `passkey/` (key derivation, share reconstruction, operation secrets), `cosigner/`
  (the gRPC connection), `enclave/` (attested gate), `persistence/` (public state only).
- The cosigner — the Rust `wasm32-wasip2` component enclave-runtime serves — lives in
  [vtxos/cosigner](https://github.com/vtxos/cosigner), with the crates it shares with this repo
  (`threshold`, `ark`, `enclave-client`, `escrow-service`) and the protos. This repo takes them as
  `ffi/`'s git dependencies, at the release tag `ffi/Cargo.toml` names; change the cosigner there.
- `protocol/` shared Dart package, generated from the cosigner's protos in the copy Cargo checked
  out for `ffi/` (`make proto` finds it). Generated Dart (`protocol/lib/src/generated`) is **not
  checked in** — run `make proto`.
- `ffi/` the merged native library the Dart side loads (`make ffi-build`), over the cosigner's
  `threshold`, `ark` and `enclave-client`.
- `e2e/` the enclave end-to-end suite and its harness; `cli/` a Dart REPL against a dev enclave,
  and Bob (`cli/bin/bob.dart`); `scripts/` what the Makefile calls. The MutinyNet deployment is
  vtxos/infra's.

## Build, Test, and Development Commands
- `make proto` regenerate Dart stubs (needs `protoc` and `dart pub global activate protoc_plugin
  21.1.2`, the generator for the protobuf 3 runtime `protocol` pins);
  `make proto-check` diffs them.
- `make ffi-build` build `ffi/target/release/libmpcwallet_ffi.so`; `core` tests need it.
- `cd core && dart test`; `cd app && flutter analyze --no-fatal-infos && flutter test`;
  `dart analyze` in `protocol/`, `cli/`, `e2e/`. Flutter may be off PATH (`~/dev/flutter/bin`).
- `make up-enclave` boots a dev enclave (docker regtest + arkd + QEMU from the `~/enclave-runtime`
  checkout, serving `make cosigner`'s wasm or `COSIGNER_WASM`); `make cli`.
- The e2e is `make e2e` (`scripts/e2e-all.sh`), from an Android emulator (API 34+, started first):
  `app/integration_test/app_test.dart`, the app's full flow through its screens, and
  `enclave_test.dart`, the wallet against the cosigner. Every passkey goes through Credential
  Manager to `app/android/testpasskey`, a software provider, and `scripts/approve-passkeys.sh`
  taps each sheet. It starts the dev enclave image pinned by digest in
  `docker-compose.enclave.yml` — the runtime's QEMU enclave and the released cosigner in one
  container, built by infra (`dev-enclave/` there) — booting its app bundle (rp id `vtxos.com`),
  with MerlinPlatform. `make enclave-image` pulls it and refuses it unless its cosigner is the
  release `ffi/Cargo.toml` names. The cosigner's settings live in `e2e/lib/e2e_profile.dart` and
  are given at start (`GUEST_ENV`, measured into PCR16 with the component). `COSIGNER_WASM` serves a
  cosigner build of your own in it instead.
- CI is `.github/workflows/ci.yml`; its `e2e` job runs `make e2e-all` on a hosted runner's KVM. Run
  it locally too before merging a change to a ceremony.

## Coding Style & Naming Conventions
- Dart: `UpperCamelCase` types, `lowerCamelCase` members, `snake_case` files. Rust: rustfmt defaults
  for new code. Both trees are hand-wrapped at 100 columns and are **not** `dart format` /
  `cargo fmt` clean at baseline — do not reformat files wholesale; match the surrounding style.
- Lints: `flutter_lints` in `app/`, `lints` in the Dart packages, clippy on the crates. Keep
  `dart analyze` clean and add no new clippy warnings.
- Comments explain why, at the depth the surrounding code does.

## Testing Guidelines
- Tests live under `*/test` (Dart, `_test.dart`) and `*/tests` (Rust). Crypto and core logic get
  unit tests; `core/test/operation_lifecycle_test.dart` drives `MpcClient` against an
  in-process cosigner; the cosigner's own tests are in vtxos/cosigner.
- A fix to a security-relevant path comes with a test that fails without it (mutation-check it).
- `make e2e` needs docker, KVM and vsock (`modprobe vsock_loopback`), and an emulator up;
  ~20 minutes warm.

## Security Invariants (see README "No key at rest", SECURITY_FINDINGS RC-3/RC-4)
- The device persists no private-key material. `WalletStore.saveClientState` refuses
  `secretShare`/`onchainSecret`/`shareBlinded`/`signingSecret` at any depth; keep it that way.
- Secrets live in a `WalletOperation`, one serialized operation at a time, disposed in a `finally`,
  and every wait on a party other than the cosigner goes through `CancelSignal.guard`. A new
  ceremony stream must be opened through `CosignerConnection._track`.
- The cosigner returns its dealt halves only through `dealt_share_for`, never its own share, and
  a change that must be durable goes through `try_seal()` before it is acted on.

## Commit & Pull Request Guidelines
- Conventional Commit prefixes (`feat:`, `fix:`, `refactor:`, `build:`), a short imperative summary,
  and a body that says what changed and why — the history is written that way.
- PRs: what was run, what was not (say so), and screenshots for Flutter UI changes.
