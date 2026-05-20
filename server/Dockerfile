FROM node:22-alpine

WORKDIR /app

# Install dependencies first (layer caching)
COPY package*.json ./
RUN npm install --omit=dev

# Copy source
COPY . .

# Expose HTTPS port
EXPOSE 3443

CMD ["node", "server.js"]