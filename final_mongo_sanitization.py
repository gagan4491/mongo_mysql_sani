#!/usr/bin/env python3

import hashlib
import os
import re
import time

from concurrent.futures import ThreadPoolExecutor, as_completed
from multiprocessing import Pool

from pymongo import MongoClient, UpdateOne
from bson import ObjectId


# ============================================================
# CONFIGURATION
# ============================================================

MONGO_HOST = "127.0.0.1"
MONGO_PORT = 27017

DB_NAME = "learninglocker_v2"
COLLECTION_NAME = "statements"

# Total collection size.
# Used only for progress/ETA display.
TOTAL_RECORDS = 192322481

# Mongo read batch
BATCH_SIZE = 100000

# CPU workers used for hashing/sanitization
WORKERS = 12

# Number of documents sent to each multiprocessing worker
# at a time.
PROCESS_CHUNK_SIZE = 1000

# MongoDB parallel write configuration
WRITE_THREADS = 4
WRITE_CHUNK_SIZE = 6250

RESUME_FILE = "./mongo_sanitize.resume"


# ============================================================
# MUST MATCH MYSQL
# ============================================================

EMAIL_SANI_SALT = "capoptix_sani_2026"
EMAIL_SANI_DOMAIN = "adt.com"
EMAIL_SANI_HASH_LENGTH = 16

EMAIL_BASE37_ALPHABET = (
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789_"
)

PII_SANI_SALT = "capoptix_pii_sani_2026"
PII_SANI_HASH_LENGTH = 32


EMAIL_SANITIZED_RE = re.compile(
    r"^[a-z0-9_]{16}@adt\.com$"
)

NAME_SANITIZED_RE = re.compile(
    r"^[a-f0-9]{32}$"
)


# ============================================================
# NORMALIZATION
# ============================================================

def normalize_hash_input(value):

    while value.startswith(" "):
        value = value[1:]

    while value.endswith(" "):
        value = value[:-1]

    value = value.translate(
        str.maketrans(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            "abcdefghijklmnopqrstuvwxyz",
        )
    )

    return value


# ============================================================
# EMAIL BASE37
# ============================================================

def email_base37_token(original):

    normalized = normalize_hash_input(original)

    digest = hashlib.sha256(
        (
            EMAIL_SANI_SALT +
            normalized
        ).encode("utf-8")
    ).digest()

    number = int.from_bytes(
        digest,
        byteorder="big",
    )

    result = []

    for _ in range(EMAIL_SANI_HASH_LENGTH):

        number, remainder = divmod(
            number,
            37,
        )

        result.append(
            EMAIL_BASE37_ALPHABET[remainder]
        )

    return "".join(result)


# ============================================================
# EMAIL
# ============================================================

def sanitize_email(value):

    if not value or "@" not in value:
        return value

    if EMAIL_SANITIZED_RE.fullmatch(value):
        return value

    return (
        email_base37_token(value)
        + "@"
        + EMAIL_SANI_DOMAIN
    )


# ============================================================
# NAME
# ============================================================

def sanitize_name(value):

    normalized = normalize_hash_input(value)

    if not normalized:
        return value

    digest = hashlib.sha256(
        (
            PII_SANI_SALT +
            normalized
        ).encode("utf-8")
    ).hexdigest()

    return digest[:PII_SANI_HASH_LENGTH]


def sanitize_name_safe(value):

    if NAME_SANITIZED_RE.fullmatch(value):
        return value

    return sanitize_name(value)


# ============================================================
# MBOX
# ============================================================

def sanitize_mbox(value):

    if not value:
        return value

    if value.startswith("mailto:"):

        email = value[len("mailto:"):]

        return (
            "mailto:" +
            sanitize_email(email)
        )

    return sanitize_email(value)


# ============================================================
# PROCESS ONE DOCUMENT
# ============================================================

def sanitize_document(doc):

    update = {}

    # --------------------------------------------------------
    # statement.actor
    # --------------------------------------------------------

    statement = doc.get("statement")

    if isinstance(statement, dict):

        actor = statement.get("actor")

        if isinstance(actor, dict):

            name = actor.get("name")

            if isinstance(name, str) and name:

                new_name = sanitize_name_safe(name)

                if new_name != name:
                    update[
                        "statement.actor.name"
                    ] = new_name

            mbox = actor.get("mbox")

            if isinstance(mbox, str) and mbox:

                new_mbox = sanitize_mbox(mbox)

                if new_mbox != mbox:
                    update[
                        "statement.actor.mbox"
                    ] = new_mbox

    # --------------------------------------------------------
    # person.display
    # --------------------------------------------------------

    person = doc.get("person")

    if isinstance(person, dict):

        display = person.get("display")

        if isinstance(display, str) and display:

            new_display = sanitize_name_safe(
                display
            )

            if new_display != display:
                update[
                    "person.display"
                ] = new_display

    # --------------------------------------------------------
    # agents
    # --------------------------------------------------------

    agents = doc.get("agents")

    if isinstance(agents, list):

        new_agents = [

            sanitize_mbox(value)
            if isinstance(value, str)
            else value

            for value in agents
        ]

        if new_agents != agents:
            update["agents"] = new_agents

    # --------------------------------------------------------
    # relatedAgents
    # --------------------------------------------------------

    related_agents = doc.get(
        "relatedAgents"
    )

    if isinstance(related_agents, list):

        new_related_agents = [

            sanitize_mbox(value)
            if isinstance(value, str)
            else value

            for value in related_agents
        ]

        if new_related_agents != related_agents:

            update[
                "relatedAgents"
            ] = new_related_agents

    return doc["_id"], update


# ============================================================
# RESUME
# ============================================================

def read_resume():

    if not os.path.exists(RESUME_FILE):
        return None

    with open(
        RESUME_FILE,
        "r",
        encoding="utf-8",
    ) as f:

        value = f.read().strip()

    if not value:
        return None

    return ObjectId(value)


def write_resume(object_id):

    temp_file = RESUME_FILE + ".tmp"

    with open(
        temp_file,
        "w",
        encoding="utf-8",
    ) as f:

        f.write(
            str(object_id) + "\n"
        )

    os.replace(
        temp_file,
        RESUME_FILE,
    )


# ============================================================
# FORMAT TIME
# ============================================================

def format_seconds(seconds):

    if seconds is None:
        return "N/A"

    seconds = int(seconds)

    days, seconds = divmod(
        seconds,
        86400,
    )

    hours, seconds = divmod(
        seconds,
        3600,
    )

    minutes, seconds = divmod(
        seconds,
        60,
    )

    if days:

        return (
            f"{days}d "
            f"{hours:02d}h "
            f"{minutes:02d}m "
            f"{seconds:02d}s"
        )

    return (
        f"{hours:02d}h "
        f"{minutes:02d}m "
        f"{seconds:02d}s"
    )


# ============================================================
# MONGO WRITE WORKER
# ============================================================

def bulk_write_chunk(
    collection,
    operations,
):

    if not operations:
        return 0

    result = collection.bulk_write(
        operations,
        ordered=False,
    )

    return result.modified_count


# ============================================================
# MAIN
# ============================================================

def main():

    script_start = time.time()

    print("=" * 70)
    print("MongoDB Fast Parallel Sanitizer")
    print("=" * 70)

    print(
        f"Mongo             : "
        f"{MONGO_HOST}:{MONGO_PORT}"
    )

    print(
        f"Database          : "
        f"{DB_NAME}"
    )

    print(
        f"Collection        : "
        f"{COLLECTION_NAME}"
    )

    print(
        f"Total records     : "
        f"{TOTAL_RECORDS:,}"
    )

    print(
        f"Batch size        : "
        f"{BATCH_SIZE:,}"
    )

    print(
        f"CPU workers       : "
        f"{WORKERS}"
    )

    print(
        f"Process chunk     : "
        f"{PROCESS_CHUNK_SIZE:,}"
    )

    print(
        f"Write threads     : "
        f"{WRITE_THREADS}"
    )

    print(
        f"Write chunk       : "
        f"{WRITE_CHUNK_SIZE:,}"
    )

    print("=" * 70)


    # ========================================================
    # CONNECT
    # ========================================================

    client = MongoClient(
        MONGO_HOST,
        MONGO_PORT,
        maxPoolSize=WRITE_THREADS + 10,
    )

    db = client[DB_NAME]

    collection = db[
        COLLECTION_NAME
    ]


    # ========================================================
    # RESUME
    # ========================================================

    last_id = read_resume()

    if last_id:

        print(
            f"Resuming after    : "
            f"{last_id}"
        )

    else:

        print(
            "No resume file. "
            "Starting from beginning."
        )


    # ========================================================
    # ONLY READ REQUIRED FIELDS
    # ========================================================

    projection = {

        "statement.actor.name": 1,

        "statement.actor.mbox": 1,

        "person.display": 1,

        "agents": 1,

        "relatedAgents": 1,
    }


    # ========================================================
    # COUNTERS
    # ========================================================

    run_processed = 0
    run_modified = 0

    batch_number = 0


    # ========================================================
    # CPU PROCESS POOL
    # ========================================================

    with Pool(
        processes=WORKERS
    ) as pool:


        while True:

            batch_number += 1

            batch_start = time.time()


            # =================================================
            # QUERY
            # =================================================

            query = {}

            if last_id is not None:

                query["_id"] = {
                    "$gt": last_id
                }


            print()
            print("=" * 70)

            print(
                f"BATCH {batch_number}"
            )

            print("=" * 70)

            print(
                f"Reading up to "
                f"{BATCH_SIZE:,} documents..."
            )


            # =================================================
            # READ
            # =================================================

            read_start = time.time()

            batch = list(

                collection.find(
                    query,
                    projection,
                )
                .sort(
                    "_id",
                    1,
                )
                .limit(
                    BATCH_SIZE
                )

            )

            read_time = (
                time.time()
                - read_start
            )


            if not batch:

                print(
                    "No more documents."
                )

                break


            batch_count = len(batch)

            batch_last_id = (
                batch[-1]["_id"]
            )


            print(
                f"Records loaded     : "
                f"{batch_count:,}"
            )

            print(
                f"Last ObjectId      : "
                f"{batch_last_id}"
            )

            print(
                f"Read time          : "
                f"{read_time:.2f}s"
            )


            # =================================================
            # PARALLEL SANITIZATION
            # =================================================

            print(
                f"Processing with "
                f"{WORKERS} workers..."
            )

            process_start = time.time()

            results = pool.map(
                sanitize_document,
                batch,
                chunksize=PROCESS_CHUNK_SIZE,
            )

            process_time = (
                time.time()
                - process_start
            )


            # Free Mongo docs as early as possible
            del batch


            # =================================================
            # CREATE UPDATE OPERATIONS
            # =================================================

            operations = []


            for object_id, update in results:

                if not update:
                    continue

                operations.append(

                    UpdateOne(

                        {
                            "_id": object_id
                        },

                        {
                            "$set": update
                        },

                    )

                )


            del results


            print(
                f"Processing time    : "
                f"{process_time:.2f}s"
            )

            print(
                f"Bulk operations   : "
                f"{len(operations):,}"
            )


            # =================================================
            # PARALLEL MONGO WRITES
            # =================================================

            modified = 0

            write_start = time.time()


            if operations:

                write_chunks = [

                    operations[
                        i:
                        i + WRITE_CHUNK_SIZE
                    ]

                    for i in range(
                        0,
                        len(operations),
                        WRITE_CHUNK_SIZE,
                    )

                ]


                print(
                    f"Write chunks      : "
                    f"{len(write_chunks)}"
                )

                print(
                    f"Writing with      : "
                    f"{WRITE_THREADS} threads"
                )


                with ThreadPoolExecutor(
                    max_workers=WRITE_THREADS
                ) as executor:


                    futures = [

                        executor.submit(
                            bulk_write_chunk,
                            collection,
                            chunk,
                        )

                        for chunk
                        in write_chunks

                    ]


                    # If ANY write fails,
                    # future.result() raises an exception.
                    # Resume file therefore will NOT advance.

                    for future in as_completed(
                        futures
                    ):

                        modified += (
                            future.result()
                        )


            write_time = (
                time.time()
                - write_start
            )


            # =================================================
            # WRITE RESUME ONLY AFTER ALL WRITES SUCCEED
            # =================================================

            write_resume(
                batch_last_id
            )

            last_id = batch_last_id


            # =================================================
            # COUNTERS
            # =================================================

            run_processed += (
                batch_count
            )

            run_modified += (
                modified
            )


            # =================================================
            # PERFORMANCE
            # =================================================

            batch_time = (
                time.time()
                - batch_start
            )

            batch_rate = (
                batch_count
                / batch_time
            )

            run_elapsed = (
                time.time()
                - script_start
            )

            run_rate = (
                run_processed
                / run_elapsed
            )


            # =================================================
            # OVERALL PROGRESS
            #
            # This assumes your resume file corresponds to
            # the approximately 48,960,000 already processed.
            # Adjust STARTING_PROCESSED below if needed.
            # =================================================

            STARTING_PROCESSED = 48960000

            overall_processed = (
                STARTING_PROCESSED
                + run_processed
            )

            remaining = max(
                TOTAL_RECORDS
                - overall_processed,
                0,
            )

            progress = (
                overall_processed
                / TOTAL_RECORDS
                * 100
            )


            if run_rate > 0:

                eta_seconds = (
                    remaining
                    / run_rate
                )

            else:

                eta_seconds = None


            # =================================================
            # OUTPUT
            # =================================================

            print()
            print(
                f"BATCH {batch_number} COMPLETE"
            )

            print("-" * 70)

            print(
                f"Processed batch    : "
                f"{batch_count:,}"
            )

            print(
                f"Modified batch     : "
                f"{modified:,}"
            )

            print()

            print(
                f"Read time          : "
                f"{read_time:.2f}s"
            )

            print(
                f"Processing time    : "
                f"{process_time:.2f}s"
            )

            print(
                f"Write time         : "
                f"{write_time:.2f}s"
            )

            print(
                f"Total batch time   : "
                f"{batch_time:.2f}s"
            )

            print()

            print(
                f"Batch rate         : "
                f"{batch_rate:,.0f} docs/sec"
            )

            print(
                f"Run average rate   : "
                f"{run_rate:,.0f} docs/sec"
            )

            print()

            print(
                f"Run processed      : "
                f"{run_processed:,}"
            )

            print(
                f"Run modified       : "
                f"{run_modified:,}"
            )

            print(
                f"Overall processed  : "
                f"{overall_processed:,}"
            )

            print(
                f"Remaining          : "
                f"{remaining:,}"
            )

            print(
                f"Progress           : "
                f"{progress:.2f}%"
            )

            print(
                f"Estimated ETA      : "
                f"{format_seconds(eta_seconds)}"
            )

            print(
                f"Resume ObjectId    : "
                f"{last_id}"
            )

            print("=" * 70)


            # =================================================
            # FINAL PARTIAL BATCH
            # =================================================

            if batch_count < BATCH_SIZE:

                print(
                    "Final batch reached."
                )

                break


    # ========================================================
    # COMPLETE
    # ========================================================

    client.close()

    total_runtime = (
        time.time()
        - script_start
    )


    print()
    print("=" * 70)
    print(
        "SANITIZATION COMPLETE"
    )
    print("=" * 70)

    print(
        f"Processed this run : "
        f"{run_processed:,}"
    )

    print(
        f"Modified this run  : "
        f"{run_modified:,}"
    )

    print(
        f"Last ID            : "
        f"{last_id}"
    )

    print(
        f"Total runtime      : "
        f"{format_seconds(total_runtime)}"
    )

    if total_runtime > 0:

        print(
            f"Average speed      : "
            f"{run_processed / total_runtime:,.0f} "
            f"docs/sec"
        )

    print("=" * 70)


if __name__ == "__main__":
    main()
