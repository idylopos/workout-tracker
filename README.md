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

## Publish on GitHub Pages

1. Create a GitHub repository and add these files.
2. Push to the repository's `main` branch.
3. In **Settings → Pages**, choose **GitHub Actions** as the source.
4. The included workflow checks and publishes the site automatically.

The app works at both a user/organization Pages domain and a repository subpath because all asset links are relative.

## Data and backups

Workout, body, sleep, and preference data are stored in that browser's local storage. Use **Data → Download backup**
regularly. Importing a valid Form / Flow JSON backup replaces the records currently stored in that browser.

The app contains no analytics, advertising, accounts, external fonts, or third-party scripts. Its Content Security Policy
allows only same-site plan files and blocks third-party connections. GitHub receives the public app and public plan files,
but it does not receive anything visitors enter into the app.

Treat exported JSON backups as private health data. Backup filenames and the local source plan are excluded by
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
