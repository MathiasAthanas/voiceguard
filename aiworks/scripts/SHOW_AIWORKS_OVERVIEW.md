# Show AIWorks Overview Script

This document explains the script that gives us a simple overview of the `aiworks` workspace.

The script is:

```text
scripts\show_aiworks_overview.py
```

## Why We Need This Script

As the AI work grows, the folder will contain datasets, manifests, prepared audio, reports, features, model files, evaluation outputs, and training experiments.

If we do not keep the structure clear, it becomes hard to know what each file means.

This script gives us a current map of the workspace.

## What The Script Does

It checks the current `aiworks` folder and writes:

```text
reports\aiworks_overview.md
```

The overview explains:

```text
what folders exist
what each folder is for
which scripts exist
which script documents exist
how many manifest rows exist
how much prepared audio exists
which reports exist
how the current pipeline connects
what should happen next
```

## How To Run It

From PowerShell:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\aiworks
python scripts\show_aiworks_overview.py
```

## When We Should Run It

We should run this after important changes, such as:

```text
adding a new script
creating a new manifest
generating prepared audio
extracting features
training a model
creating evaluation results
```

This keeps the workspace understandable for us and for anyone else who needs to follow what we are doing.
