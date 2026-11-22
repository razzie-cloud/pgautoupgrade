#!/usr/bin/env bash
set -Eeo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/../postgres-docker-entrypoint.sh"

export POSTGRES_PASSWORD=test PGAUTO_ONESHOT=yes PGAUTO_DEVEL=
for version in 16 17 18 19 20; do
    mkdir -p "$TEST_ROOT/bin/$version/bin"
    touch "$TEST_ROOT/bin/$version/bin/postgres"
    chmod +x "$TEST_ROOT/bin/$version/bin/postgres"
done

# Mock installed binaries and container ownership; stop after moving the test data.
[() {
    if [[ "$1" == '!' && "$2" == -x && "$3" == /usr/local-pg*/bin/postgres ]]; then
        builtin [ ! -x "$TEST_ROOT/bin/${3#/usr/local-pg}" ]
    else
        builtin [ "$@"
    fi
}
id() { echo 1000; }
docker_create_db_directories() { command mkdir -p "$PGDATA"; }
mkdir() {
    command mkdir "$@"
    if [[ "$*" == "$PGDATA/new" ]]; then exit 42; fi
}

check_status() {
    local expected=$1 status=0
    (_main postgres) > "$TEST_ROOT/output" 2>&1 || status=$?
    if [ "$status" -ne "$expected" ]; then
        cat "$TEST_ROOT/output"
        echo "Expected status $expected, got $status for source $(cat "$PGAUTO_TEST_SOURCE/PG_VERSION") and target $PGTARGET"
        exit 1
    fi
}

checks=0
for version in 9.5 9.6 10 11 12 13 14 15 16 17 18 19 20 invalid; do
    for target in 16 17 18 19 20 21; do
        PGDATA="$TEST_ROOT/case-$version-$target"
        PGAUTO_TEST_SOURCE=$PGDATA
        PGTARGET=$target.0
        command mkdir -p "$PGDATA"
        echo "$version" > "$PGDATA/PG_VERSION"
        echo payload > "$PGDATA/data"
        expected=9
        if [[ "$version" == "$target" ]]; then
            expected=0
        elif [[ "$version" =~ ^[1-9][0-9]*$ ]] && [ "$version" -ge 16 ] && [ "$version" -lt "$target" ]; then
            expected=42
        fi
        check_status "$expected"
        if [ "$expected" -eq 42 ]; then
            [ "$(cat "$PGDATA/old/PG_VERSION")" = "$version" ]
            [ "$(cat "$PGDATA/old/data")" = payload ]
        else
            [ "$(cat "$PGDATA/PG_VERSION")" = "$version" ]
            [ "$(cat "$PGDATA/data")" = payload ]
            [ ! -e "$PGDATA/old" ]
            [ ! -e "$PGDATA/upgrade_in_progress.lock" ]
        fi
        checks=$((checks + 1))
    done
done

for layout in legacy versioned; do
    for target in 19 20; do
        root="$TEST_ROOT/$layout-$target"
        PGDATA="$root/$target/docker"
        PGTARGET=$target.0
        PGAUTO_TEST_SOURCE=$root
        version=17
        if [ "$layout" = versioned ]; then PGAUTO_TEST_SOURCE="$root/18/docker"; version=18; fi
        command mkdir -p "$PGAUTO_TEST_SOURCE"
        echo "$version" > "$PGAUTO_TEST_SOURCE/PG_VERSION"
        echo payload > "$PGAUTO_TEST_SOURCE/data"
        check_status 42
        [ "$(cat "$PGDATA/old/PG_VERSION")" = "$version" ]
        [ "$(cat "$PGDATA/old/data")" = payload ]
        [ ! -e "$PGAUTO_TEST_SOURCE/PG_VERSION" ]
        checks=$((checks + 1))
    done
done

root="$TEST_ROOT/current-cluster"
PGTARGET=19.0
PGDATA="$root/19/docker"
PGAUTO_TEST_SOURCE=$PGDATA
command mkdir -p "$root/18/docker" "$PGDATA"
echo 18 > "$root/18/docker/PG_VERSION"
echo 19 > "$PGDATA/PG_VERSION"
check_status 0
[ "$(cat "$root/18/docker/PG_VERSION")" = 18 ]
[ "$(cat "$PGDATA/PG_VERSION")" = 19 ]
checks=$((checks + 1))

PGDATA="$TEST_ROOT/empty/19/docker"
docker_find_database
[ "$PGAUTO_SOURCE_PGDATA" = "$PGDATA" ]
[ "$MOVING_TO_NEW_STRUCTURE" -eq 0 ]
[ ! -e "$PGDATA" ]
checks=$((checks + 1))

# Missing binaries, ambiguous clusters and interrupted upgrades must preserve data.
for failure in missing-binaries multiple-clusters locked; do
    root="$TEST_ROOT/$failure"
    PGTARGET=19.0
    PGDATA="$root/19/docker"
    PGAUTO_TEST_SOURCE="$root/18/docker"
    command mkdir -p "$PGAUTO_TEST_SOURCE"
    echo 18 > "$PGAUTO_TEST_SOURCE/PG_VERSION"
    case "$failure" in
        missing-binaries) rm "$TEST_ROOT/bin/18/bin/postgres"; expected=9 ;;
        multiple-clusters) command mkdir -p "$root/17/docker"; echo 17 > "$root/17/docker/PG_VERSION"; expected=9 ;;
        locked) touch "$PGAUTO_TEST_SOURCE/upgrade_in_progress.lock"; expected=1 ;;
    esac
    check_status "$expected"
    [ "$(cat "$PGAUTO_TEST_SOURCE/PG_VERSION")" = 18 ]
    [ ! -e "$PGDATA/old" ]
    checks=$((checks + 1))
done

echo "$checks version and data-directory checks passed."
