// Chat application state and logic

// State
let chatState = null;
let pollInterval = null;
let pendingMessageEl = null;

// DOM elements
const messagesEl = document.getElementById('messages');
const chatForm = document.getElementById('chat-form');
const userMessageEl = document.getElementById('user-message');
const sendBtn = document.getElementById('send-btn');
const resetBtn = document.getElementById('reset-btn');
const temperatureEl = document.getElementById('temperature');
const tempValueEl = document.getElementById('temp-value');
const thinkingEnabledEl = document.getElementById('thinking-enabled');
const thinkingOptionsEl = document.getElementById('thinking-options');
const toastEl = document.getElementById('toast');

// Update temperature display
temperatureEl.addEventListener('input', () => {
  tempValueEl.textContent = temperatureEl.value;
});

// Toggle thinking options
thinkingEnabledEl.addEventListener('change', () => {
  thinkingOptionsEl.style.display = thinkingEnabledEl.checked ? 'block' : 'none';
});

// Show toast notification
function showToast(message, type = 'info') {
  toastEl.textContent = message;
  toastEl.className = `toast ${type} show`;
  setTimeout(() => {
    toastEl.className = 'toast';
  }, 3000);
}

// Add message to chat
function addMessage(role, content, meta = null) {
  // Remove empty state if present
  const emptyState = messagesEl.querySelector('.empty-state');
  if (emptyState) emptyState.remove();

  const messageEl = document.createElement('div');
  messageEl.className = `message ${role}`;

  // Use markdown rendering for assistant messages, escape for others
  const renderedContent = (role === 'assistant')
    ? Markdown.render(content)
    : Markdown.escapeHtml(content).replace(/\n/g, '<br>');

  const roleLabel = role === 'user' ? 'You' : (role === 'error' ? 'Error' : 'Assistant');
  let html = `<div class="message-role">${roleLabel}</div><div class="message-content">${renderedContent}</div>`;
  if (meta) {
    let metaText = `Tokens: ${meta.input || 0} in / ${meta.output || 0} out`;
    if (meta.duration) {
      metaText += ` | ${meta.duration}s`;
    }
    html += `<div class="message-tokens">${metaText}</div>`;
  }

  messageEl.innerHTML = html;
  messagesEl.appendChild(messageEl);
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

// Get settings
function getSettings() {
  return {
    api_url: document.getElementById('api-url').value,
    model: document.getElementById('model').value,
    system_prompt: document.getElementById('system-prompt').value,
    temperature: parseFloat(temperatureEl.value),
    max_tokens: parseInt(document.getElementById('max-tokens').value) || 0,
    thinking_enabled: thinkingEnabledEl.checked,
    thinking_effort: document.getElementById('thinking-effort').value,
    thinking_budget: parseInt(document.getElementById('thinking-budget').value),
    schema: document.getElementById('schema').value
  };
}

// Add pending message placeholder
function addPendingMessage() {
  // Remove empty state if present
  const emptyState = messagesEl.querySelector('.empty-state');
  if (emptyState) emptyState.remove();

  pendingMessageEl = document.createElement('div');
  pendingMessageEl.className = 'message assistant pending';
  pendingMessageEl.innerHTML = `
    <div class="message-role">Assistant</div>
    <div class="message-content">
      <div class="typing-indicator">
        <span></span><span></span><span></span>
      </div>
    </div>
  `;
  messagesEl.appendChild(pendingMessageEl);
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

// Remove pending message placeholder
function removePendingMessage() {
  if (pendingMessageEl) {
    pendingMessageEl.remove();
    pendingMessageEl = null;
  }
}

// Send chat message
async function sendMessage(message) {
  // Add user message to UI
  addMessage('user', message);

  // Add pending placeholder
  addPendingMessage();

  const settings = getSettings();
  const payload = {
    message: message,
    chat: chatState,
    ...settings
  };

  try {
    const response = await fetch('/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Request failed');
    }

    // Start polling for result
    startPolling();
  } catch (error) {
    removePendingMessage();
    showToast(error.message, 'error');
  }
}

// Poll for result
function startPolling() {
  if (pollInterval) clearInterval(pollInterval);

  pollInterval = setInterval(async () => {
    try {
      const response = await fetch('/result');

      if (response.status === 200) {
        const result = await response.json();
        stopPolling();
        handleResult(result);
      }
      // 204 = no result yet, keep polling
    } catch (error) {
      console.error('Poll error:', error);
    }
  }, 500);
}

// Stop polling
function stopPolling() {
  if (pollInterval) {
    clearInterval(pollInterval);
    pollInterval = null;
  }
  removePendingMessage();
}

// Handle result
function handleResult(result) {
  if (result.success) {
    addMessage('assistant', result.message.content, {
      input: result.message.input_tokens,
      output: result.message.output_tokens,
      duration: result.message.duration
    });
    chatState = result.chat;
    showToast('Response received', 'success');
  } else {
    addMessage('error', `Error: ${result.error.type} - ${result.error.message}`);
    showToast(`Error: ${result.error.message}`, 'error');
  }
}

// Reset conversation
function resetConversation() {
  chatState = null;
  pendingMessageEl = null;
  stopPolling();
  messagesEl.innerHTML = '<div class="empty-state">Start a conversation by typing a message below.</div>';
  fetch('/reset');
  showToast('Conversation reset', 'info');
}

// Form submit handler
chatForm.addEventListener('submit', (e) => {
  e.preventDefault();
  const message = userMessageEl.value.trim();
  if (message) {
    sendMessage(message);
    userMessageEl.value = '';
  }
});

// Reset button handler
resetBtn.addEventListener('click', resetConversation);

// Keyboard shortcut: Ctrl/Cmd + Enter to send
userMessageEl.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
    e.preventDefault();
    chatForm.dispatchEvent(new Event('submit'));
  }
});
