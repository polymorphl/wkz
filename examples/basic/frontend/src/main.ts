import { invoke } from '@wkz/bridge'
import './style.css'

async function runDemo(): Promise<void> {
  const status = document.getElementById('status')!
  try {
    const result = await invoke<string>('ping')
    status.textContent = `bridge ✓ — ping → "${result}"`
    status.className = 'ok'
  } catch (err) {
    status.textContent = `bridge ✗ — ${String(err)}`
    status.className = 'error'
  }
}

runDemo()
