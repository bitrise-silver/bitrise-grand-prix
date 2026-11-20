# Builds the session server and the controller site, and bundles the exported game.
#
# The Godot export is not built here: run `npm run build:game` first so that
# game/export/web exists (it is git-ignored), then `docker build -t bitrise-grand-prix .`

FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.base.json ./
COPY packages/shared/package.json packages/shared/
COPY packages/server/package.json packages/server/
COPY packages/controller/package.json packages/controller/
RUN npm ci
COPY packages packages
COPY game/tracks game/tracks
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8787 \
    DATA_DIR=/data \
    CONTROLLER_DIR=/app/controller \
    GAME_DIR=/app/game
COPY --from=build /app/packages/server/package.json ./package.json
RUN npm install --omit=dev --no-audit --no-fund
COPY --from=build /app/packages/server/dist ./dist
COPY --from=build /app/packages/controller/dist ./controller
COPY game/export/web ./game
VOLUME /data
EXPOSE 8787
USER node
CMD ["node", "dist/server.js"]
