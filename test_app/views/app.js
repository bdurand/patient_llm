// Chat application state and logic

// State
let chatState = null;
const pendingRequests = new Map(); // Map of request_id -> {pollInterval, messageEl}

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
function addPendingMessage(requestId) {
  // Remove empty state if present
  const emptyState = messagesEl.querySelector('.empty-state');
  if (emptyState) emptyState.remove();

  const pendingMessageEl = document.createElement('div');
  pendingMessageEl.className = 'message assistant pending';
  pendingMessageEl.dataset.requestId = requestId;
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

  return pendingMessageEl;
}

// Remove pending message placeholder
function removePendingMessage(requestId) {
  const messageEl = document.querySelector(`[data-request-id="${requestId}"]`);
  if (messageEl) {
    messageEl.remove();
  }
}

// Send chat message
async function sendMessage(message) {
  // Add user message to UI
  addMessage('user', message);

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

    const result = await response.json();
    const requestId = result.request_id;

    // Add pending placeholder
    const messageEl = addPendingMessage(requestId);

    // Start polling for this specific request
    startPolling(requestId, messageEl);
  } catch (error) {
    showToast(error.message, 'error');
  }
}

// Poll for result
function startPolling(requestId, messageEl) {
  const pollInterval = setInterval(async () => {
    try {
      const response = await fetch(`/result?request_id=${encodeURIComponent(requestId)}`);

      if (response.status === 200) {
        const result = await response.json();
        handleResult(requestId, result);
        stopPolling(requestId);
      } else if (response.status === 400) {
        // Invalid request_id
        const error = await response.json();
        stopPolling(requestId);
        showToast(error.error || 'Invalid request', 'error');
      }
      // 204 = no result yet, keep polling
    } catch (error) {
      console.error('Poll error:', error);
    }
  }, 500);

  pendingRequests.set(requestId, { pollInterval, messageEl });
}

// Stop polling
function stopPolling(requestId) {
  const pending = pendingRequests.get(requestId);
  if (pending) {
    clearInterval(pending.pollInterval);
    pendingRequests.delete(requestId);
  }
}

// Handle result
function handleResult(requestId, result) {
  const pending = pendingRequests.get(requestId);
  const messageEl = pending?.messageEl;

  if (messageEl) {
    // Replace the pending placeholder with actual content
    if (result.success) {
      const renderedContent = Markdown.render(result.message.content);
      let metaText = `Tokens: ${result.message.input_tokens || 0} in / ${result.message.output_tokens || 0} out`;
      if (result.message.duration) {
        metaText += ` | ${result.message.duration}s`;
      }

      messageEl.className = 'message assistant';
      messageEl.innerHTML = `
        <div class="message-role">Assistant</div>
        <div class="message-content">${renderedContent}</div>
        <div class="message-tokens">${metaText}</div>
      `;
      chatState = result.chat;
      showToast('Response received', 'success');
    } else {
      const errorContent = Markdown.escapeHtml(`Error: ${result.error.type} - ${result.error.message}`).replace(/\n/g, '<br>');
      messageEl.className = 'message error';
      messageEl.innerHTML = `
        <div class="message-role">Error</div>
        <div class="message-content">${errorContent}</div>
      `;
      showToast(`Error: ${result.error.message}`, 'error');
    }
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }
}

// Reset conversation
function resetConversation() {
  chatState = null;

  // Stop all pending polls
  for (const [requestId, _] of pendingRequests) {
    stopPolling(requestId);
  }
  pendingRequests.clear();

  messagesEl.innerHTML = '<div class="empty-state">Start a conversation by typing a message below.</div>';
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
