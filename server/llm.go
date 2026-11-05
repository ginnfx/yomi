package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const (
	defaultLLMURL   = "https://api.deepseek.com"
	defaultLLMModel = "deepseek-flash"
	llmTimeout      = 3 * time.Minute
	llmMaxTokens    = 8000
	llmAttempts     = 3
	llmRetryDelay   = 5 * time.Second
	llmMaxReply     = 4 << 20
)

// LLMClient calls an OpenAI-style chat API and expects JSON back. The key never leaves
// this file: it's only ever sent as a header, and errors describe status codes, not requests.
type LLMClient struct {
	URL        string
	Key        string
	Model      string
	HTTP       *http.Client
	RetryDelay time.Duration
}

// newLLMClient returns nil when no key is set, which turns every AI feature off.
func newLLMClient(cfg Config, client *http.Client) *LLMClient {
	if cfg.LLMKey == "" {
		return nil
	}
	url := cfg.LLMURL
	if url == "" {
		url = defaultLLMURL
	}
	model := cfg.LLMModel
	if model == "" {
		model = defaultLLMModel
	}
	return &LLMClient{URL: url, Key: cfg.LLMKey, Model: model, HTTP: client, RetryDelay: llmRetryDelay}
}

var errBlankReply = errors.New("the AI returned a blank reply")

// JSON sends the prompts and decodes the reply into out. JSON mode can legitimately return
// blank content, so blank or undecodable replies are tried again a few times.
func (c *LLMClient) JSON(ctx context.Context, system, user string, out any) error {
	var last error
	for attempt := 0; attempt < llmAttempts; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(c.RetryDelay):
			}
		}
		reply, err := c.complete(ctx, system, user)
		if err == nil {
			if strings.TrimSpace(reply) == "" {
				last = errBlankReply
				continue
			}
			if err = json.Unmarshal([]byte(reply), out); err == nil {
				return nil
			}
			last = fmt.Errorf("the AI returned invalid JSON: %w", err)
			continue
		}
		var status *llmStatusError
		if errors.As(err, &status) && !status.isRetryable() {
			return err
		}
		last = err
	}
	return last
}

type llmStatusError struct{ code int }

func (e *llmStatusError) Error() string { return fmt.Sprintf("the AI service answered %d", e.code) }

func (e *llmStatusError) isRetryable() bool {
	return e.code == http.StatusTooManyRequests || e.code >= http.StatusInternalServerError
}

func (c *LLMClient) complete(ctx context.Context, system, user string) (string, error) {
	body, err := json.Marshal(map[string]any{
		"model":           c.Model,
		"max_tokens":      llmMaxTokens,
		"response_format": map[string]string{"type": "json_object"},
		// Thinking is DeepSeek's default and would spend the reply on hidden reasoning.
		"thinking": map[string]string{"type": "disabled"},
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": user},
		},
	})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+c.Key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return "", fmt.Errorf("couldn't reach the AI service: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, llmMaxReply))
		return "", &llmStatusError{code: resp.StatusCode}
	}
	var reply struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, llmMaxReply)).Decode(&reply); err != nil {
		return "", fmt.Errorf("unexpected AI reply: %w", err)
	}
	if len(reply.Choices) == 0 {
		return "", nil
	}
	return reply.Choices[0].Message.Content, nil
}
