if (process.argv.includes('--version')) {
  console.log('fixture-native 1.0');
  process.exit(0);
}

const argumentsList = process.argv.slice(2);
if (argumentsList.includes('-p') || argumentsList.includes('--prompt')) {
  throw new Error('Prompt leaked into native command line');
}

const chunks = [];
process.stdin.on('data', chunk => chunks.push(chunk));
process.stdin.on('end', () => {
  const content = Buffer.concat(chunks).toString('utf8');
  console.log(JSON.stringify({ type: 'session.start', id: 'start', data: { arguments: argumentsList } }));
  console.log(JSON.stringify({ type: 'model.call_start', data: { model: 'fixture-model' } }));
  console.log(JSON.stringify({ type: 'assistant.message', id: 'message', data: { content } }));
});