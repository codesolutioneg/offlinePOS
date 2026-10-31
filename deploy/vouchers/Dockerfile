FROM dart:stable
WORKDIR /app
COPY pubspec.yaml .
RUN dart pub get
COPY lib lib
COPY tools/voucher_server.dart bin/server.dart
ENV VOUCHER_HOST=0.0.0.0
ENV VOUCHER_PORT=8787
CMD ["dart", "run", "bin/server.dart"]
