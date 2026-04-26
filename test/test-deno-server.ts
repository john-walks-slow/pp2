// Simple Deno HTTP server for testing
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const PORT = 19983;

serve(() => new Response("PP2 Deno Test OK\n"), { port: PORT });
console.log(`Deno HTTP server running on port ${PORT}`);