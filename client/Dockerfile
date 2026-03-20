# build stage
ARG NODE_VERSION=24.14.0-alpine

FROM node:${NODE_VERSION} AS build

WORKDIR /app

COPY package*.json ./

RUN npm ci

COPY . .

RUN npm run build

# production stage
#FROM nginx:alpine
#
#COPY --from=build /app/dist /usr/share/nginx/html
#
#COPY nginx.conf /etc/nginx/conf.d/default.conf
#
#EXPOSE 80
#
#CMD ["nginx", "-g", "daemon off;"]

# production stage
FROM node:${NODE_VERSION}

WORKDIR /app

RUN npm install -g serve

COPY --from=build /app/dist ./dist

EXPOSE 3000

RUN chown -R node:node /app

USER node

CMD ["serve", "-s", "dist", "-l", "3000"]



