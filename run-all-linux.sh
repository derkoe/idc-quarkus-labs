#!/bin/bash
set -e


# keep track of the last executed command
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
# echo an error message before exiting
trap 'echo "\"${last_command}\" command filed with exit code $?."' EXIT

cd "$(dirname "$0")"

function create_database_container {
  printf "Starting PostgreSQL in pod $1"
  podman run --ulimit memlock=-1:-1 -d --rm=true --pod=$1-pod --memory-swappiness=0 --name $1-db -e POSTGRES_USER=todo -e POSTGRES_PASSWORD=todo -e POSTGRES_DB=todo-db postgres:10.5 > /dev/null
  # Waiting for the database to start
  while ! (podman exec -it $1-db psql -U todo todo-db -c "select 1" > /dev/null 2>&1)
  do
    sleep .2
    printf "."
  done
  echo "[DONE]"
}

function prepopulate_database {
  printf "Creating database tables and content "
  podman exec -it $1-db psql -U todo todo-db -c "create table Todo (
        id int8 not null,
          completed boolean not null,
          ordering int4,
          title varchar(255),
          url varchar(255),
          primary key (id)
      )" > /dev/null
  printf "."

  podman exec -it $1-db psql -U todo todo-db -c "create sequence hibernate_sequence start with 1 increment by 1" > /dev/null
  printf "."
  podman exec -it $1-db psql -U todo todo-db -c "alter table if exists Todo drop constraint if exists unique_title_constraint" > /dev/null
  printf "."
  podman exec -it $1-db psql -U todo todo-db -c "alter table if exists Todo add constraint unique_title_constraint unique (title)" > /dev/null
  printf "."
  podman exec -it $1-db psql -U todo todo-db -c "INSERT INTO todo(id, title, completed, ordering, url) VALUES (nextval('hibernate_sequence'), 'Introduction to Quarkus', true, 0, null)" > /dev/null
  printf "."
  podman exec -it $1-db psql -U todo todo-db -c "INSERT INTO todo(id, title, completed, ordering, url) VALUES (nextval('hibernate_sequence'), 'Hibernate with Panache', false, 1, null)" > /dev/null
  printf "."
  podman exec -it $1-db psql -U todo todo-db -c "INSERT INTO todo(id, title, completed, ordering, url) VALUES (nextval('hibernate_sequence'), 'Visit Quarkus web site', false, 2, 'https://quarkus.io')" > /dev/null
  printf "."
  podman exec -it $1-db psql -U todo todo-db -c "INSERT INTO todo(id, title, completed, ordering, url) VALUES (nextval('hibernate_sequence'), 'Star Quarkus project', false, 3, 'https://github.com/quarkusio/quarkus/')" > /dev/null
  echo "[DONE]"
}

function stop_pod {
  printf "Stopping and removing pod $1 \t" 
  podman pod stop $1-pod > /dev/null 2>&1 || true
  podman pod rm -f $1-pod > /dev/null 2>&1 || true 
  echo "[DONE]"
}

function create_pod {
  printf "Creating pod $1 using port $2 \t"
  podman pod create --name=$1-pod -p $2 > /dev/null
  echo "[DONE]"
}


stop_pod    spring-boot
stop_pod    quarkus-jvm
stop_pod    quarkus-native

create_pod  spring-boot     8080
create_pod  quarkus-jvm     8081
create_pod  quarkus-native  8082


create_database_container   spring-boot
prepopulate_database        spring-boot
create_database_container   quarkus-jvm
prepopulate_database        quarkus-jvm
create_database_container   quarkus-native
prepopulate_database        quarkus-native

printf "Starting Spring Boot container on port 8080 "
podman run -d --rm --cpus=1 --memory=1G --pod="spring-boot-pod" --name=spring-boot spring/hello > /dev/null
while ! (curl -sf http://localhost:8080 > /dev/null)
do
  sleep .2
  printf "."
done
echo "[DONE]"

printf "Starting Quarkus JVM container on port 8081 "
podman run -d --rm --cpus=1 --memory=1G --pod="quarkus-jvm-pod" --name=quarkus-jvm -e QUARKUS_HTTP_PORT=8081 -e QUARKUS_DATASOURCE_URL=jdbc:postgresql://localhost/todo-db quarkus/hello-jvm > /dev/null
while ! (curl -sf http://localhost:8081 > /dev/null)
do
  sleep .2
  printf "."
done
echo "[DONE]"


printf "Starting Quarkus native container on port 8082 "
podman run -d --rm --cpus=1 --memory=1G --pod="quarkus-native-pod" --name=quarkus-native -e QUARKUS_HTTP_PORT=8082 -e QUARKUS_DATASOURCE_URL=jdbc:postgresql://localhost/todo-db quarkus/hello-native > /dev/null
while ! (curl -sf http://localhost:8082 > /dev/null)
do
  sleep .2
  printf "."
done
echo "[DONE]"

echo "Displaying stats for containers: "
podman stats --no-stream $(test "podman" = "podman" && echo "--no-reset") spring-boot quarkus-jvm quarkus-native

trap - EXIT
