'use strict';

const { startServer } = require('./mock-backend');

const sock = process.argv[2];
startServer(sock)
  .then((b) => {
    process.stdout.write('ready ' + b.path + '\n');
    const shutdown = () => {
      b.close().then(() => process.exit(0));
    };
    process.on('SIGTERM', shutdown);
    process.on('SIGINT', shutdown);
  })
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
