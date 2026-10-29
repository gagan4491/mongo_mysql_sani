# Run the MongoDB sanitizer on a fresh system

## 1. Install Python and prepare the files

Use Python 3.12 with pip and virtual environment support. Download Python for your operating system from https://www.python.org/downloads/ . On Windows, enable the Python PATH option during installation.

On Ubuntu/Debian, you can instead install the distribution's Python 3 and tools:

```sh
sudo apt update
sudo apt install -y python3 python3-pip python3-venv
```

Place these three files in one folder, then open a terminal in that folder:

- mongo_sanitize.py (the supplied script, unchanged)
- requirements.txt
- SETUP.md

## 2. Create an isolated environment and install dependencies

macOS / Linux:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Windows Command Prompt:

```bat
py -3 -m venv .venv
.venv\Scripts\activate.bat
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Verify the imports:

```sh
python -c "from pymongo import MongoClient, UpdateOne; from bson import ObjectId; print('Dependencies OK')"
```

PyMongo is the only third-party dependency. It includes bson. hashlib, os, re, time, concurrent.futures, and multiprocessing are part of Python. Do not install a separate package named bson.

## 3. Make the MongoDB data available

The script expects an existing MongoDB server and populated collection. Installing requirements.txt does not install MongoDB Server or restore your data.

Its defaults are:

```python
MONGO_HOST = "127.0.0.1"
MONGO_PORT = 27017
DB_NAME = "learninglocker_v2"
COLLECTION_NAME = "statements"
```

If MongoDB is on another machine, change MONGO_HOST and MONGO_PORT in mongo_sanitize.py. If you need a local server, follow the installation instructions for your OS at https://www.mongodb.com/docs/manual/installation/ and restore the intended database. Check your server/driver combination at https://www.mongodb.com/docs/drivers/compatibility/ . Older MongoDB servers may require a different PyMongo version than this requirements file allows.

The supplied script has no authentication or TLS configuration. If the server requires either, update its MongoClient(...) connection before running. The account needs read and update access to the target collection. Keep credentials out of the script; use your deployment's connection configuration or an environment variable.

## 4. Review the settings before the first run

This script updates the database in place and has no dry-run mode. Take a database backup and try it on a restored test copy first; the hashes cannot restore original names or email addresses.

- Confirm the host, database, and collection.
- The resume logic assumes every document _id is a BSON ObjectId.
- Set STARTING_PROCESSED = 0 inside main() for a new run. Its supplied value, 48960000, only affects progress/ETA; it does not skip records.
- Set TOTAL_RECORDS to the collection's actual size if you want meaningful progress estimates. It does not limit the scan.
- For an initial run on a smaller machine, start with WORKERS = 2, BATCH_SIZE = 1000, WRITE_THREADS = 1, and WRITE_CHUNK_SIZE = 1000. Increase after checking memory, CPU, and database load. The supplied batch size of 100000 holds many records and update operations in memory.
- Keep the hashing salts, normalization, and domain settings aligned with your MySQL sanitization if cross-system matching is required.

The script sanitizes only the fields explicitly listed in sanitize_document(); it does not scan every possible field for personal data.

## 5. Check connectivity and the collection

With the default unauthenticated localhost settings, run this read-only check:

```sh
python -c "from pymongo import MongoClient; c=MongoClient('127.0.0.1',27017,serverSelectionTimeoutMS=5000); print('Ping:',c.admin.command('ping')); d=c['learninglocker_v2']; print('Collection exists:','statements' in d.list_collection_names()); c.close()"
```

Adjust the connection to match the script if you changed it. A successful ping confirms connectivity, not update permission. Confirm that the intended collection exists and contains your restored data before proceeding.

## 6. Run

From the folder containing the script, with the virtual environment activated:

```sh
python -u mongo_sanitize.py
```

Run it as a saved .py file, rather than pasting it into a notebook or interactive Python prompt, because it uses multiprocessing.

For a long-running Linux/macOS job that should continue after terminal logout:

```sh
nohup .venv/bin/python -u mongo_sanitize.py > sanitize.log 2>&1 &
```

Follow the log:

```sh
tail -f sanitize.log
```

Run only one instance against a given collection/resume file.

## 7. Resume after interruption

Run the same command again from the same folder. The script writes mongo_sanitize.resume in the current working directory after all writes for a batch succeed, then resumes after that ObjectId. An interrupted batch may be retried; the script's sanitized-value checks are intended to avoid rehashing already-sanitized values.

When moving an ongoing job to a fresh system, copy its matching mongo_sanitize.resume along with the script and connect to the same dataset. When starting on a different dataset, use a separate folder without an old resume file. An unrelated resume file can skip records.

Keep the resume file after completion. Documents inserted later with _id values at or below the saved checkpoint, or records edited behind the checkpoint, are not revisited automatically.

## Troubleshooting

- ModuleNotFoundError: activate .venv and install requirements using that environment's python.
- bson import errors: recreate .venv and install only requirements.txt; the separate bson package can conflict with PyMongo.
- Connection refused / server selection timeout: confirm MongoDB is running, the host/port are correct, and network access is allowed. 127.0.0.1 always means the machine running this script.
- Authentication failed / unauthorized: configure authentication and collection read/update permissions.
- Memory pressure: lower BATCH_SIZE and WORKERS.
- InvalidId when resuming: check that the resume file contains a valid ObjectId from this dataset.

Official driver setup reference: https://www.mongodb.com/docs/languages/python/pymongo-driver/current/get-started/

These setup files were prepared by inspecting the supplied script. The sanitizer has not been run against your database.
