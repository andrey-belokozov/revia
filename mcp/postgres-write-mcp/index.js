#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import pg from 'pg';

const { Pool } = pg;

const CONNECTION_STRING = process.env.PG_CONNECTION_STRING || '';

if (!CONNECTION_STRING) {
  process.stderr.write('ERROR: PG_CONNECTION_STRING env var is not set\n');
  process.exit(1);
}

const pool = new Pool({ connectionString: CONNECTION_STRING, ssl: { rejectUnauthorized: false } });

const server = new Server(
  { name: 'postgres-write', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'execute',
      description: 'Execute any SQL statement (SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, etc.)',
      inputSchema: {
        type: 'object',
        properties: {
          sql: { type: 'string', description: 'SQL statement to execute' },
        },
        required: ['sql'],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name !== 'execute') {
    throw new Error(`Unknown tool: ${request.params.name}`);
  }

  const sql = request.params.arguments?.sql;
  if (!sql) throw new Error('sql parameter is required');

  const client = await pool.connect();
  try {
    const result = await client.query(sql);
    const text = result.rows?.length > 0
      ? JSON.stringify(result.rows, null, 2)
      : `OK — ${result.command} ${result.rowCount ?? ''} row(s) affected`;
    return { content: [{ type: 'text', text }] };
  } catch (err) {
    return { content: [{ type: 'text', text: `ERROR: ${err.message}` }], isError: true };
  } finally {
    client.release();
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
