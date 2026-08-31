# Form / Flow workout tracker

A private, mobile-first workout and health log built around the included evidence-based weekly program. It is a static
site: no account, server, database, or paid service is required.

## Add another weekly plan

Create `plans/your-plan/plan.json` and push it to `main`. The build discovers valid plan folders automatically and adds
them to the app's workout-plan picker. Copy the included example and follow [plans/README.md](plans/README.md); no app
code or registry edit is required.

Plan files are public programming content. They must not contain personal information. Each plan's workout history and
exercise settings are kept separate in the visitor's browser.

## Use locally

Because the app uses JavaScript modules, serve the folder with a small local web server:

```sh
python3 -m http.server 8080
```

Then open `http://localhost:8080`.

## Log extra cardio

On any scheduled training day, choose **+ Add extra activity** below the planned exercises. Select walking, cycling,
elliptical, swimming, running, or a custom activity; then choose time, time plus calories, distance plus time, or
distance-only logging. Every option includes RPE.

Select **Save this setup as a reusable activity** to add the configuration to the activity picker. Reusable activities
and completed extra-cardio records are stored inside the encrypted browser vault and included in JSON backups. The Week
view shows the selected week’s combined planned and extra cardio. Progress starts with a four-week training and
recovery snapshot, then shows exercise detail and an eight-week cardio duration trend.

## During a workout

Changes on the Today screen are automatically saved as an encrypted draft. If the browser reloads or discards the tab,
the draft will be restored. With **Keep unlocked for two hours** selected, the browser retains a non-exportable
decryption key until the fixed expiry time, so a reload does not require the passphrase again. The passphrase itself is
never stored. **Save workout** confirms the draft as a completed workout log.

For repeated working sets, enter the first set and choose **Fill empty sets from set 1**. The app copies load and reps
(or the equivalent primary measurements) into blank fields while leaving RIR/RPE and any values already entered alone.
**Use Last** keeps the number of sets currently planned for today and fills every set with the reusable values from the
final logged set of the previous workout. It leaves every completion box and RIR/RPE field clear. It also clears
pull-up performance/recovery qualification checks, so importing values
cannot mark the current exercise complete. The lookup searches every earlier saved workout and encrypted draft, so
skipped weeks do not hide the most recent entry.

Every built-in exercise includes a collapsible **Quick form guide** covering setup, execution, the main thing to watch,
and a substitute when appropriate. Folder-based plans can provide the same guidance in `plan.json`.
Exercises with a substitute advertise **alternative available** in the guide header. Assisted Nordic hamstrings also
show an **Alternatives** button for logging machine curls, slider/stability-ball curls, or bridge walkouts without
replacing the planned exercise or rewriting earlier logs.

Pull-up sessions include a six-step performance roadmap with separate same-day technique and following-morning
recovery checks. The Week view groups the 16 long-run stages into four phases, retains each workout’s assigned stage,
and offers explicit repeat, step-back, and criteria-gated advance actions.

The built-in plan uses a brief Monday lunge-twist warm-up and a separately logged, low-fatigue Wednesday Mobility A
sequence. Each mobility movement is logged on its own rather than as one combined set.

On the first unlocked visit each day, a non-blocking **Daily Check-in** asks only for inputs that are due: last night's
sleep and any missing following-morning workout response from the previous two days. Answers save immediately to the
encrypted vault. Following-morning answers update the original workout record, while nightly sleep records calculate
the current weekly average without replacing legacy weekly sleep logs. The check-in can be deferred or skipped.

The current built-in plan is also available as [WORKOUT_PLAN.md](WORKOUT_PLAN.md). It is generated from `lib.js` during
`npm run build`; after changing the built-in plan, run `npm run sync-plan` and commit the updated Markdown together with
the code change.

## Publish on GitHub Pages

1. Create a GitHub repository and add these files.
2. Push to the repository's `main` branch.
3. In **Settings → Pages**, choose **GitHub Actions** as the source.
4. The included workflow checks and publishes the site automatically.

The app works at both a user/organization Pages domain and a repository subpath because all asset links are relative.

## Data and backups

Workout logs, in-progress workout drafts, body measurements, sleep records, reusable activities, and preferences are
encrypted with AES-GCM before being stored in that browser. The encryption key is derived from a user-created passphrase
and is normally kept in memory. When the two-hour option is selected, a non-exportable Web Crypto key is retained in
that browser with a fixed expiry; it is not the passphrase and cannot be exported as raw key material. Existing
unencrypted Form / Flow records are migrated into the encrypted vault after the user creates a passphrase.

The passphrase is never stored or uploaded and cannot be recovered. If it is forgotten, the only in-app recovery is to
erase the encrypted vault and start over. **Data → Lock app** immediately clears the remembered unlock key; use it before
leaving a shared device.

Use **Data → Download backup** regularly. Importing a valid Form / Flow JSON backup replaces the records currently stored
in that browser.

The app contains no analytics, advertising, accounts, external fonts, or third-party scripts. Its Content Security Policy
allows only same-site plan files and blocks third-party connections. GitHub receives the public app and public plan files,
but it does not receive anything visitors enter into the app.

Exported JSON backups are intentionally portable and are not passphrase-encrypted, so treat them as private health data.
Backup filenames and the local source plan are excluded by
`.gitignore` to help prevent accidental publication. Use **Data → Erase local data** before giving someone access to a
shared browser profile or device.

## Checks

```sh
npm test
npm run build
```

The production-ready static files are written to `dist/`.

## Health note

This app organizes informational exercise guidance; it does not diagnose or treat medical conditions. Consult a doctor,
sports physiotherapist, pelvic-health physiotherapist, or qualified trainer for diagnosis, treatment, persistent symptoms,
or individualized clearance.
