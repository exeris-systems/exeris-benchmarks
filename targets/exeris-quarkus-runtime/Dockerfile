FROM eclipse-temurin:26-jre
WORKDIR /app
# The module must be packaged on the host before running docker build.
COPY targets/exeris-quarkus-runtime/target/*-runner.jar /app/app.jar

ENTRYPOINT ["java", "--enable-preview", "-jar", "/app/app.jar"]
