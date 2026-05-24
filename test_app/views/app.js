// Chat application state and logic

// State
let chatState = null;
const pendingRequests = new Map(); // Map of request_id -> {pollInterval, messageEl, requestContext}
let attachments = []; // Array of {id, name, mediaType, data, dataUrl}
let attachmentIdCounter = 0;

// DOM elements
const messagesEl = document.getElementById('messages');
const chatForm = document.getElementById('chat-form');
const userMessageEl = document.getElementById('user-message');
const sendBtn = document.getElementById('send-btn');
const resetBtn = document.getElementById('reset-btn');
const temperatureEl = document.getElementById('temperature');
const tempValueEl = document.getElementById('temp-value');
const topPEl = document.getElementById('top-p');
const topPValueEl = document.getElementById('top-p-value');
const presencePenaltyEl = document.getElementById('presence-penalty');
const presencePenaltyValueEl = document.getElementById('presence-penalty-value');
const frequencyPenaltyEl = document.getElementById('frequency-penalty');
const frequencyPenaltyValueEl = document.getElementById('frequency-penalty-value');
const thinkingEnabledEl = document.getElementById('thinking-enabled');
const thinkingOptionsEl = document.getElementById('thinking-options');
const toolsEnabledEl = document.getElementById('tools-enabled');
const toolsOptionsEl = document.getElementById('tools-options');
const metadataEntriesEl = document.getElementById('metadata-entries');
const addMetadataBtn = document.getElementById('add-metadata-btn');
const toastEl = document.getElementById('toast');
const fileInputEl = document.getElementById('file-input');
const attachBtn = document.getElementById('attach-btn');
const attachmentPreviewsEl = document.getElementById('attachment-previews');
const chatInputArea = document.getElementById('chat-input-area');
const providerEl = document.getElementById('provider');
const customApiSettingsEl = document.getElementById('custom-api-settings');

// Update temperature display
temperatureEl.addEventListener('input', () => {
  tempValueEl.textContent = temperatureEl.value;
});

// Update top_p display
topPEl.addEventListener('input', () => {
  topPValueEl.textContent = topPEl.value;
});

// Update presence_penalty display
presencePenaltyEl.addEventListener('input', () => {
  presencePenaltyValueEl.textContent = presencePenaltyEl.value;
});

// Update frequency_penalty display
frequencyPenaltyEl.addEventListener('input', () => {
  frequencyPenaltyValueEl.textContent = frequencyPenaltyEl.value;
});

// Toggle individual sampling fields
document.querySelectorAll('.sampling-toggle').forEach(toggle => {
  toggle.addEventListener('change', () => {
    const target = document.getElementById(toggle.dataset.target);
    target.disabled = !toggle.checked;
  });
});

// Toggle thinking options
thinkingEnabledEl.addEventListener('change', () => {
  thinkingOptionsEl.style.display = thinkingEnabledEl.checked ? 'block' : 'none';
});

// Toggle tools options
toolsEnabledEl.addEventListener('change', () => {
  toolsOptionsEl.style.display = toolsEnabledEl.checked ? 'block' : 'none';
});

// Provider selection
providerEl.addEventListener('change', () => {
  customApiSettingsEl.style.display = providerEl.value === 'custom' ? '' : 'none';
  const selected = providerEl.selectedOptions[0];
  if (selected && selected.dataset.defaultModel) {
    document.getElementById('model').value = selected.dataset.defaultModel;
  }
});

// Load available premium providers
async function loadProviders() {
  try {
    const response = await fetch('/providers');
    if (response.ok) {
      const providers = await response.json();
      providers.forEach(p => {
        const option = document.createElement('option');
        option.value = p.name;
        option.textContent = p.label;
        if (p.default_model) option.dataset.defaultModel = p.default_model;
        providerEl.appendChild(option);
      });
    }
  } catch (_error) {
    // Providers endpoint not available; keep only Custom
  }
}

loadProviders();

// Show toast notification
function showToast(message, type = 'info') {
  toastEl.textContent = message;
  toastEl.className = `toast ${type} show`;
  setTimeout(() => {
    toastEl.className = 'toast';
  }, 3000);
}

// --- Attachment handling ---

function addFilesToAttachments(files) {
  for (const file of files) {
    const reader = new FileReader();
    const id = ++attachmentIdCounter;
    reader.onload = (e) => {
      const dataUrl = e.target.result;
      // Extract base64 data (strip the data:...;base64, prefix)
      const base64 = dataUrl.split(',')[1];
      const attachment = {
        id,
        name: file.name,
        mediaType: file.type || 'application/octet-stream',
        data: base64,
        dataUrl
      };
      attachments.push(attachment);
      renderAttachmentPreview(attachment);
      // Once we have attachments, the text field is no longer required
      userMessageEl.required = (attachments.length === 0);
    };
    reader.readAsDataURL(file);
  }
}

function renderAttachmentPreview(attachment) {
  const chip = document.createElement('div');
  chip.className = 'attachment-chip';
  chip.dataset.attachmentId = attachment.id;

  const isImage = attachment.mediaType.startsWith('image/');
  if (isImage) {
    const img = document.createElement('img');
    img.src = attachment.dataUrl;
    img.alt = attachment.name;
    chip.appendChild(img);
  } else {
    const icon = document.createElement('span');
    icon.className = 'attachment-chip-icon';
    icon.textContent = '\u{1F4C4}';
    chip.appendChild(icon);
  }

  const nameSpan = document.createElement('span');
  nameSpan.className = 'attachment-chip-name';
  nameSpan.textContent = attachment.name;
  chip.appendChild(nameSpan);

  const removeBtn = document.createElement('button');
  removeBtn.type = 'button';
  removeBtn.className = 'attachment-chip-remove';
  removeBtn.innerHTML = '&times;';
  removeBtn.title = 'Remove';
  removeBtn.addEventListener('click', () => {
    attachments = attachments.filter(a => a.id !== attachment.id);
    chip.remove();
    userMessageEl.required = (attachments.length === 0);
  });
  chip.appendChild(removeBtn);

  attachmentPreviewsEl.appendChild(chip);
}

function clearAttachments() {
  attachments = [];
  attachmentPreviewsEl.innerHTML = '';
  userMessageEl.required = true;
}

function serializeAttachments() {
  return attachments.map(a => ({
    name: a.name,
    media_type: a.mediaType,
    data: a.data
  }));
}

// Attach button → file picker
attachBtn.addEventListener('click', () => fileInputEl.click());

fileInputEl.addEventListener('change', () => {
  if (fileInputEl.files.length > 0) {
    addFilesToAttachments(fileInputEl.files);
    fileInputEl.value = '';
  }
});

// Drag-and-drop on the input area
chatInputArea.addEventListener('dragenter', (e) => {
  e.preventDefault();
  chatInputArea.classList.add('drag-over');
});

chatInputArea.addEventListener('dragover', (e) => {
  e.preventDefault();
  chatInputArea.classList.add('drag-over');
});

chatInputArea.addEventListener('dragleave', (e) => {
  // Only remove highlight when leaving the input area entirely
  if (!chatInputArea.contains(e.relatedTarget)) {
    chatInputArea.classList.remove('drag-over');
  }
});

chatInputArea.addEventListener('drop', (e) => {
  e.preventDefault();
  chatInputArea.classList.remove('drag-over');
  if (e.dataTransfer.files.length > 0) {
    addFilesToAttachments(e.dataTransfer.files);
  }
});

// Paste files (e.g. screenshots) into the textarea
userMessageEl.addEventListener('paste', (e) => {
  const files = [];
  if (e.clipboardData && e.clipboardData.items) {
    for (const item of e.clipboardData.items) {
      if (item.kind === 'file') {
        const file = item.getAsFile();
        if (file) files.push(file);
      }
    }
  }
  if (files.length > 0) {
    addFilesToAttachments(files);
  }
});

function cloneChatState(state) {
  if (state == null) {
    return null;
  }

  return JSON.parse(JSON.stringify(state));
}

function parseChatState(serializedChatState) {
  if (!serializedChatState) {
    return null;
  }

  try {
    return JSON.parse(serializedChatState);
  } catch (_error) {
    return null;
  }
}

function trimConversationAfter(messageEl) {
  let currentEl = messageEl.nextElementSibling;

  while (currentEl) {
    const nextEl = currentEl.nextElementSibling;
    if (currentEl.dataset.requestId) {
      stopPolling(currentEl.dataset.requestId);
    }
    currentEl.remove();
    currentEl = nextEl;
  }
}

// Add message to chat
function addMessage(role, content, meta = null, messageAttachments = null) {
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

  let attachmentsHtml = '';
  if (messageAttachments && messageAttachments.length > 0) {
    const badges = messageAttachments.map(a => {
      if (a.media_type && a.media_type.startsWith('image/') && a.data) {
        return `<img class="message-attachment-thumb" src="data:${Markdown.escapeHtml(a.media_type)};base64,${a.data}" alt="${Markdown.escapeHtml(a.name)}" title="${Markdown.escapeHtml(a.name)}">`;
      }
      return `<span class="message-attachment-badge">\u{1F4C4} ${Markdown.escapeHtml(a.name)}</span>`;
    }).join('');
    attachmentsHtml = `<div class="message-attachments">${badges}</div>`;
  }

  let html = `<div class="message-role">${roleLabel}</div>${attachmentsHtml}<div class="message-content">${renderedContent}</div>`;
  if (meta) {
    let metaText = `Tokens: ${meta.input || 0} in / ${meta.output || 0} out`;
    if (meta.duration) {
      metaText += ` | ${meta.duration}s`;
    }
    html += `
      <div class="message-footer">
        <div class="message-tokens">${metaText}</div>
      </div>
    `;
  }

  // Add resend button for user messages
  if (role === 'user') {
    html += `
      <div class="message-footer user-message-footer">
        <button type="button" class="message-resend-btn" title="Resend message" aria-label="Resend message">↩</button>
      </div>
    `;
  }

  messageEl.innerHTML = html;
  messagesEl.appendChild(messageEl);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return messageEl;
}

// Get settings
function getSettings() {
  const provider = providerEl.value;
  const settings = {
    provider: provider,
    model: document.getElementById('model').value,
    system_prompt: document.getElementById('system-prompt').value,
    thinking_enabled: thinkingEnabledEl.checked,
    thinking_effort: document.getElementById('thinking-effort').value,
    thinking_budget: parseInt(document.getElementById('thinking-budget').value),
    schema: document.getElementById('schema').value
  };

  if (provider === 'custom') {
    settings.api_url = document.getElementById('api-url').value;
    settings.api_path = document.getElementById('api-path').value;
    const authorization = document.getElementById('authorization').value.trim();
    if (authorization) settings.authorization = authorization;
  }

  // Sampling parameters (only include individually enabled ones)
  if (!temperatureEl.disabled) {
    settings.temperature = parseFloat(temperatureEl.value);
  }
  if (!topPEl.disabled) {
    const topP = parseFloat(topPEl.value);
    if (topP < 1) settings.top_p = topP;
  }
  if (!presencePenaltyEl.disabled) {
    const presencePenalty = parseFloat(presencePenaltyEl.value);
    if (presencePenalty !== 0) settings.presence_penalty = presencePenalty;
  }
  if (!frequencyPenaltyEl.disabled) {
    const frequencyPenalty = parseFloat(frequencyPenaltyEl.value);
    if (frequencyPenalty !== 0) settings.frequency_penalty = frequencyPenalty;
  }
  if (!document.getElementById('max-tokens').disabled) {
    settings.max_tokens = parseInt(document.getElementById('max-tokens').value) || 0;
  }
  if (!document.getElementById('top-logprobs').disabled) {
    const topLogprobs = parseInt(document.getElementById('top-logprobs').value) || 0;
    if (topLogprobs > 0) settings.top_logprobs = topLogprobs;
  }

  // Tool settings
  if (toolsEnabledEl.checked) {
    settings.tools_enabled = true;

    const allowedTools = Array.from(document.querySelectorAll('input[name="allowed-tools"]:checked'))
      .map(cb => cb.value);
    settings.allowed_tools = allowedTools;

    const toolChoice = document.getElementById('tool-choice').value;
    if (toolChoice) settings.tool_choice = toolChoice;

    if (document.getElementById('parallel-tool-calls').checked) {
      settings.parallel_tool_calls = true;
    }

    const maxToolCalls = parseInt(document.getElementById('max-tool-calls').value) || 0;
    if (maxToolCalls > 0) settings.max_tool_calls = maxToolCalls;
  }

  // Response control
  const truncation = document.getElementById('truncation').value;
  if (truncation) settings.truncation = truncation;

  if (document.getElementById('store').checked) {
    settings.store = true;
  }

  const serviceTier = document.getElementById('service-tier').value;
  if (serviceTier) settings.service_tier = serviceTier;

  const includeChecked = Array.from(document.querySelectorAll('input[name="include"]:checked'))
    .map(cb => cb.value);
  if (includeChecked.length > 0) settings.include = includeChecked;

  // Advanced
  const safetyId = document.getElementById('safety-identifier').value.trim();
  if (safetyId) settings.safety_identifier = safetyId;

  const cacheKey = document.getElementById('prompt-cache-key').value.trim();
  if (cacheKey) settings.prompt_cache_key = cacheKey;

  const metadata = getMetadata();
  if (Object.keys(metadata).length > 0) settings.metadata = metadata;

  return settings;
}

// Add pending message placeholder
function addPendingMessage(requestId, options = {}) {
  const {replaceEl = null} = options;

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
  if (replaceEl) {
    replaceEl.replaceWith(pendingMessageEl);
  } else {
    messagesEl.appendChild(pendingMessageEl);
  }
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
async function sendMessage(message, options = {}) {
  const addUserBubble = options.addUserBubble !== false;
  const replaceAssistantEl = options.replaceAssistantEl || null;
  const chatBefore = options.chatOverride === undefined ? chatState : options.chatOverride;
  const chatSnapshot = cloneChatState(chatBefore);
  const messageAttachments = options.attachments || null;

  if (addUserBubble) {
    const newUserMessageEl = addMessage('user', message, null, messageAttachments);
    newUserMessageEl.dataset.userMessage = message;
    newUserMessageEl.dataset.chatBefore = JSON.stringify(chatSnapshot);
    if (messageAttachments && messageAttachments.length > 0) {
      newUserMessageEl.dataset.attachments = JSON.stringify(messageAttachments);
    }
  }

  const settings = getSettings();
  const payload = {
    message: message,
    session: chatSnapshot,
    ...settings
  };

  if (messageAttachments && messageAttachments.length > 0) {
    payload.attachments = messageAttachments;
  }

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

    if (replaceAssistantEl) {
      trimConversationAfter(replaceAssistantEl);
      chatState = chatSnapshot;
    }

    // Add pending placeholder
    const messageEl = addPendingMessage(requestId, {replaceEl: replaceAssistantEl});

    // Start polling for this specific request
    startPolling(requestId, messageEl, {
      userMessage: message,
      chatBefore: chatSnapshot
    });

    return true;
  } catch (error) {
    showToast(error.message, 'error');
    return false;
  }
}

// Poll for result
function startPolling(requestId, messageEl, requestContext) {
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

  pendingRequests.set(requestId, {pollInterval, messageEl, requestContext});
}

// Stop polling
function stopPolling(requestId) {
  const pending = pendingRequests.get(requestId);
  if (pending) {
    clearInterval(pending.pollInterval);
    pendingRequests.delete(requestId);
  }
}

// Format the latency breakdown: total wall-clock time, summed HTTP request
// time, and the async overhead (the difference) added by the request pipeline.
function formatLatency(message) {
  const total = message.total_duration;
  const http = message.http_duration;

  const parts = [];
  if (total != null) parts.push(`Total: ${total.toFixed(3)}s`);
  if (http != null) parts.push(`HTTP: ${http.toFixed(3)}s`);
  if (total != null && http != null) {
    const overhead = Math.max(0, total - http);
    parts.push(`Async overhead: ${overhead.toFixed(3)}s`);
  }

  if (message.request_count > 1) {
    parts.push(`Tool calls: ${message.request_count - 1}`);
  }

  return parts.join(' · ');
}

// Handle result
function handleResult(requestId, result) {
  const pending = pendingRequests.get(requestId);
  const messageEl = pending?.messageEl;
  const requestContext = pending?.requestContext;

  if (messageEl) {
    // Replace the pending placeholder with actual content
    if (result.success) {
      let renderedContent;
      if (result.message.structured) {
        // Display structured responses as pretty-formatted JSON
        let formattedJson;
        try {
          formattedJson = JSON.stringify(JSON.parse(result.message.content), null, 2);
        } catch (_e) {
          formattedJson = result.message.content;
        }
        renderedContent = `<pre class="structured-json">${Markdown.escapeHtml(formattedJson)}</pre>`;
      } else {
        renderedContent = Markdown.render(result.message.content);
      }
      let metaText = `Tokens: ${result.message.input_tokens || 0} in / ${result.message.output_tokens || 0} out`;
      const latency = formatLatency(result);
      if (latency) {
        metaText += ` | ${latency}`;
      }

      messageEl.className = 'message assistant';
      messageEl.innerHTML = `
        <div class="message-role">Assistant</div>
        <div class="message-content">${renderedContent}</div>
        <div class="message-footer">
          <div class="message-tokens">${metaText}</div>
          <button type="button" class="message-refresh-btn" title="Regenerate response" aria-label="Regenerate response">↻</button>
        </div>
      `;

      if (requestContext?.userMessage) {
        messageEl.dataset.userMessage = requestContext.userMessage;
        messageEl.dataset.chatBefore = JSON.stringify(requestContext.chatBefore);
      }

      chatState = result.session;
      showToast('Response received', 'success');
    } else {
      let errorContent = Markdown.escapeHtml(`Error: ${result.error.type} - ${result.error.message}`).replace(/\n/g, '<br>');
      if (result.error.details) {
        errorContent += '<br><br><pre>' + Markdown.escapeHtml(JSON.stringify(result.error.details, null, 2)) + '</pre>';
      }
      messageEl.className = 'message error';
      messageEl.innerHTML = `
        <div class="message-role">Error</div>
        <div class="message-content">${errorContent}</div>
      `;

      delete messageEl.dataset.userMessage;
      delete messageEl.dataset.chatBefore;
      showToast(`Error: ${result.error.message}`, 'error');
    }
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }
}

async function refreshAssistantMessage(messageEl) {
  const userMessage = messageEl.dataset.userMessage;
  if (!userMessage) {
    showToast('Unable to regenerate this response', 'error');
    return;
  }

  const chatBefore = parseChatState(messageEl.dataset.chatBefore);

  await sendMessage(userMessage, {
    addUserBubble: false,
    chatOverride: chatBefore,
    replaceAssistantEl: messageEl
  });
}

async function resendUserMessage(userMessageEl) {
  const message = userMessageEl.dataset.userMessage;
  if (message === undefined) {
    showToast('Unable to resend this message', 'error');
    return;
  }

  const chatBefore = parseChatState(userMessageEl.dataset.chatBefore);
  const savedAttachments = userMessageEl.dataset.attachments
    ? JSON.parse(userMessageEl.dataset.attachments)
    : null;

  // Remove this user message and everything that came after it
  trimConversationAfter(userMessageEl);
  userMessageEl.remove();

  // Restore empty state if the conversation is now empty
  if (!messagesEl.querySelector('.message')) {
    messagesEl.innerHTML = '<div class="empty-state">Start a conversation by typing a message below.</div>';
  }

  // Re-submit the message with the session state from before it was sent
  await sendMessage(message, {
    chatOverride: chatBefore,
    attachments: savedAttachments
  });
}

// Reset conversation
function resetConversation() {
  chatState = null;
  clearAttachments();

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
  const currentAttachments = serializeAttachments();
  if (message || currentAttachments.length > 0) {
    sendMessage(message, {attachments: currentAttachments.length > 0 ? currentAttachments : null});
    userMessageEl.value = '';
    clearAttachments();
  }
});

// Reset button handler
resetBtn.addEventListener('click', resetConversation);

messagesEl.addEventListener('click', async (event) => {
  const refreshBtn = event.target.closest('.message-refresh-btn');
  if (refreshBtn) {
    if (refreshBtn.disabled) return;

    const assistantMessageEl = refreshBtn.closest('.message.assistant');
    if (!assistantMessageEl) return;

    refreshBtn.disabled = true;
    await refreshAssistantMessage(assistantMessageEl);

    if (document.body.contains(refreshBtn)) {
      refreshBtn.disabled = false;
    }
    return;
  }

  const resendBtn = event.target.closest('.message-resend-btn');
  if (resendBtn) {
    if (resendBtn.disabled) return;

    const userMessageEl = resendBtn.closest('.message.user');
    if (!userMessageEl) return;

    resendBtn.disabled = true;
    await resendUserMessage(userMessageEl);
    // The element is removed on success, so no need to re-enable
  }
});

// Metadata editor
function addMetadataRow(key = '', value = '') {
  const entry = document.createElement('div');
  entry.className = 'metadata-entry';
  entry.innerHTML = `
    <input type="text" placeholder="key" value="${Markdown.escapeHtml(key)}" class="metadata-key" autocomplete="off">
    <input type="text" placeholder="value" value="${Markdown.escapeHtml(value)}" class="metadata-value" autocomplete="off">
    <button type="button" class="remove-metadata-btn" title="Remove">&times;</button>
  `;
  metadataEntriesEl.appendChild(entry);
}

function getMetadata() {
  const metadata = {};
  metadataEntriesEl.querySelectorAll('.metadata-entry').forEach(entry => {
    const key = entry.querySelector('.metadata-key').value.trim();
    const value = entry.querySelector('.metadata-value').value.trim();
    if (key) metadata[key] = value;
  });
  return metadata;
}

addMetadataBtn.addEventListener('click', () => addMetadataRow());

metadataEntriesEl.addEventListener('click', (event) => {
  const removeBtn = event.target.closest('.remove-metadata-btn');
  if (removeBtn) {
    removeBtn.closest('.metadata-entry').remove();
  }
});

// Keyboard shortcut: Ctrl/Cmd + Enter to send
userMessageEl.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
    e.preventDefault();
    chatForm.dispatchEvent(new Event('submit'));
  }
});
