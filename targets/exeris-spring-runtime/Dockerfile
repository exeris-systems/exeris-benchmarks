FROM eclipse-temurin:26-jre
WORKDIR /app
# The jar must be prebuilt on the host before running docker build.
COPY targets/exeris-spring-runtime/target/exeris-spring-runtime-1.0.0-SNAPSHOT.jar /app/app.jar

ENTRYPOINT ["java", "--enable-preview", "-jar", "/app/app.jar"]
