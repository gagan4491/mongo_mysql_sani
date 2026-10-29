#!/usr/bin/env python3
"""Check MongoDB connectivity without modifying data."""
import os
import sys

from pymongo import MongoClient
from pymongo.errors import PyMongoError

# Defaults match mongo_sanitize.py. Edit these if needed.
MONGO_HOST = "127.0.0.1"
MONGO_PORT = 27017
DB_NAME = "learninglocker_v2"
COLLECTION_NAME = "statements"
TIMEOUT_MS = 5000

# Optional: set MONGO_URI for authentication, TLS, or a remote deployment.
# The URI is deliberately never printed, as it may contain credentials.
MONGO_URI = os.environ.get("MONGO_URI")


def main():
    client = None
    try:
        options = dict(
            serverSelectionTimeoutMS=TIMEOUT_MS,
            connectTimeoutMS=TIMEOUT_MS,
            socketTimeoutMS=TIMEOUT_MS,
            appname="mongo-connection-check",
        )
        client = (
            MongoClient(MONGO_URI, **options)
            if MONGO_URI
            else MongoClient(MONGO_HOST, MONGO_PORT, **options)
        )
        print("Connection source:", "MONGO_URI environment variable" if MONGO_URI
              else f"{MONGO_HOST}:{MONGO_PORT}")
        print("Configured database:", DB_NAME)
        print("Configured collection:", COLLECTION_NAME)
        client.admin.command("ping")
        print("Connection: SUCCESS (MongoDB answered ping)")

        nodes = sorted(client.nodes)
        print("Discovered server(s):", ", ".join(f"{h}:{p}" for h, p in nodes)
              or "Not reported by driver")
        print("Topology:", client.topology_description.topology_type_name)

        # Metadata may be restricted even when ping succeeds.
        for label, command, field in (
            ("MongoDB version", "buildInfo", "version"),
            ("Server-reported address", "hello", "me"),
        ):
            try:
                result = client.admin.command(command)
                print(f"{label}:", result.get(field, "Not reported"))
                if command == "hello" and result.get("setName"):
                    print("Replica set:", result["setName"])
            except PyMongoError as exc:
                print(f"{label}: unavailable ({type(exc).__name__})")

        try:
            # Read at most one _id; never print document contents.
            document = client[DB_NAME][COLLECTION_NAME].find_one({}, {"_id": 1})
            print("Collection read: SUCCESS")
            print("Data check:", "At least one document exists" if document is not None
                  else "No documents found (collection may be empty or absent)")
        except PyMongoError as exc:
            print(f"Collection read: FAILED ({type(exc).__name__})")
            print("Connection works, but collection read access could not be verified.")
            return 2
        return 0
    except (PyMongoError, ValueError) as exc:
        print(f"Connection: FAILED ({type(exc).__name__})")
        print("Check the host/port or MONGO_URI, MongoDB service, network, "
              "credentials, and TLS settings.")
        # Avoid printing raw exception text, which can expose connection details.
        return 1
    finally:
        if client is not None:
            client.close()


if __name__ == "__main__":
    sys.exit(main())
