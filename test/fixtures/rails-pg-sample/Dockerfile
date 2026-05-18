FROM ruby:3.2-alpine
RUN apk add --no-cache build-base postgresql-dev tzdata git
WORKDIR /app
COPY . .
CMD ["sh", "-c", "tail -f /dev/null"]
