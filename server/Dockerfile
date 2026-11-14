FROM node:22-alpine
WORKDIR /app
RUN apk add --no-cache openssl
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
ENV NODE_ENV=production
EXPOSE 3443
CMD ["node", "server.js"]
