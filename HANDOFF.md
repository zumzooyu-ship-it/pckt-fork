# Pckt fork — hand-off / progress log

This folder is a full copy of **github.com/zumzooyu-ship-it/pckt-fork** (a Flutter/Android app) with new
features added on top. It is a git repo: the first commit is the untouched upstream code, every later commit is
our work, so `git log` / `git diff <first-commit> HEAD` shows exactly what changed.

> **To continue in a new chat:** say *"Continue the Pckt work. Read `pckt-app/HANDOFF.md` and do the items under
> 'Next up'."* Everything needed to resume is in this file.

## How to get the code onto your machine

* Preview page (Next.js, project root) has two buttons: **Download source (.tar.gz)** and **Download patch**.
* Patch route: `/api/download?format=patch` → apply on your fork with `git apply pckt-changes.patch`
  (then `flutter pub get && dart run build_runner build -d`).
* Tarball route: `/api/download` (includes `.git`).

## Build / verify (what we ran in the sandbox)

```sh
flutter pub get
dart run build_runner build -d     # regenerates lib/data/db/database.g.dart (schema is now v5)
flutter analyze                    # only the pre-existing `material.dart deprecated` infos remain
flutter test                       # see "Verification status"
dart run tool/gen_icons.js         # (node tool/gen_icons.js) only if you add new Phosphor icons
```

## Done

| # | Request | Status | Where |
|---|---------|--------|-------|
| 1 | Custom message templates ("Teach Pckt") | ✅ | `lib/ingestion/templates/template_engine.dart`, `lib/features/templates/templates_screen.dart`; entry points: Settings → *Message templates*, SMS card → *Teach Pckt*, SMS log → *Teach Pckt* button on every ignored/unreadable message |
| 2 | Transfer as a 3rd type | ✅ | Add sheet: Expense / Income / **Transfer** (from-account → to-account) creates two linked legs (`transferPairId`); detail sheet shows/pairs/unpairs the other leg; SMS self-transfer detection now also pairs |
| 3 | Split / repayment linking (Axio-style) | ✅ | `TxnLinks` table + `Transactions.linkedMinor`. `TxnMoney.amountIn()` subtracts it, so **every total, budget, chart, CSV and the AI tools** use "your share". UI: `lib/features/activity/link_sheet.dart` (`LinksPanel`) shows on both the payment and the received money |
| 4 | Manual bills & subscriptions with reminders | ✅ | `Bills` table, `lib/features/bills/` (`bill_schedule.dart` = pure rules, `bills_screen.dart`), reminders via `flutter_local_notifications` zonedSchedule in `lib/core/notifications.dart` + `BillRemindersController` (`lib/providers_extra.dart`). Weekly / 2-weekly / monthly / quarterly / 6-monthly / yearly / once; remind N days before **and** on the day (≈9 am); mark paid (optionally adds the expense) / skip / pause |
| 5 | Account balance "as per last message" | ✅ | `lib/ingestion/parser/balance_parser.dart` (reads *Avl Bal*, ignores card *available limit*), stored on `Accounts.balanceMinor/balanceAt`; dashboard **Account balances** card + Accounts screen (tap to type one manually). Back-filled once from already-stored messages |
| 6 | Scan-period bug | ✅ | Root cause: the period picker only existed on first *Connect*. Now Settings → SMS has **Scan period** (1 m / 3 m / 6 m / 1 y / 2 y / All) → `SmsSyncController.rescan()`; shows "Reading messages since …". Nothing is deleted when you change it |
| – | Import / export | ✅ | JSON backup is a raw table dump, so the 3 new tables + new columns are included/restored automatically. CSV got 3 appended columns: `type`, `settled_amount`, `your_share` |
| – | Extras | ✅ | "Coming up" bills card on the dashboard; "Teach" suggestions list of possibly-missed messages |

## Design notes (read before changing things)

* **Schema v5** (`lib/data/db/tables.dart`, migration in `database.dart`). New code lives in
  `lib/data/db/extras.dart` (an extension on `AppDatabase`) so `database.dart` stays close to upstream.
* **Template engine:** a template stores, per tapped field, the last 2 words *before* the value and the first word
  *after* it. Digits / spacing / month names inside anchors are generalised. User templates run **before** the
  built-in parser (`IngestionService._parse`). Saving a template re-runs it over stored *ignored/unreadable* messages.
* **`linkedMinor`** is denormalised from `txn_links`; always change links through `linkRepayment` / `removeLink`
  (they recompute). Links only allowed between same-currency, non-transfer debit ↔ credit.
* Bumping `smsParserVersion` in `providers.dart` wipes SMS-derived transactions (links on them cascade away) — avoid
  unless the parser really changed. Template changes do **not** need a bump.
* Bill reminders use **inexact** alarms (no exact-alarm permission needed); they re-arm on every app start and every
  bill edit, and after reboot via the manifest receivers.

## Verification status (honest)

* `flutter analyze`: no errors (only the 43 pre-existing `deprecated_member_use` infos about `material.dart`).
* New unit tests pass: `test/templates_test.dart` (template engine, balance parser, bill schedule). Parser tests pass.
* The DB-backed tests (ingestion, backup, migration…) **could not run in the sandbox** (SQLCipher needs a newer glibc),
  so run `flutter test` on your machine. One existing assertion was updated for the 3 new CSV columns
  (`test/currency_db_test.dart`).
* **Not run on a phone/emulator** — no Android SDK in the sandbox. Please smoke-test: add a bill (notification
  permission prompt), Scan period, Teach Pckt on a real SMS, add a Transfer, link a repayment.

## Next up (suggested order)

1. Run the app on a device; fix any layout nits in the new screens.
2. Native `SmsAlertReceiver.kt` (instant notifications) doesn't know about user templates — transactions still appear
   on the next sync; teach it or call into Dart.
3. One-tap "Add to bills" from the Recurring screen (`recurring_screen.dart` already detects subscriptions).
4. "Friend owes me" tracker: show unsettled shares (payments where you recorded a split but nobody paid yet).
5. Expose bills/balances/links to the AI assistant tools (`lib/llm/agent/finance_tools.dart`).
6. Unit tests for `linkRepayment`, `addTransfer`, `applyBalance` (need a machine that can load SQLCipher).
7. Optional: bill ↔ transaction auto-match (mark a bill paid when a matching debit arrives).
