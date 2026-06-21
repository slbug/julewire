# Attribute Keys

Attributes are record-local fields for integrations, processors, and
formatters. They do not propagate. Integration-specific detail belongs under a
namespace such as `attributes.web`, `attributes.job`, or
`attributes.messaging`; those namespaces are emitted by default.

Neutral keys are formatter coordination fields stored in the record's `neutral`
section. Formatters can promote them to provider-native output, but the default
formatter strips the section from emitted JSON so the same fact is not logged
twice. User attributes such as `my_app.some_key` remain normal emitted
attributes.

Neutral keys track current OpenTelemetry semantic-convention names where those
names fit Julewire records. Julewire intentionally follows current/edge names
instead of pinning this page to one semconv release. Julewire still owns this
contract: upstream semconv changes make a key worth rechecking, not
automatically emitted.

## HTTP

| Key | Meaning |
| --- | --- |
| `http.request.method` | HTTP request method. |
| `url.full` | Full filtered request URL when available. |
| `url.path` | Request path. |
| `http.response.status_code` | HTTP response status. |
| `user_agent.original` | Raw user-agent value. |
| `client.address` | Client address or remote IP. |
| `http.response.body.size` | Response body size in bytes. |

## Code

| Key | Meaning |
| --- | --- |
| `code.file.path` | Source file path. |
| `code.line.number` | Source line number. |
| `code.function.name` | Source function, method, or label. |

## Jobs

Current OpenTelemetry semconv does not provide a general job namespace that fits
ActiveJob-style execution summaries, so these are Julewire neutral job keys.

| Key | Meaning |
| --- | --- |
| `job.system` | Job framework or runtime, such as `active_job`. |
| `job.name` | Job class or logical job name. |
| `job.id` | Framework job id. |
| `job.provider_id` | Backend provider job id. |
| `job.queue.name` | Queue name. |
| `job.priority` | Queue priority. |
| `job.execution_count` | Framework execution count or attempt count. |
| `job.enqueued_at` | Enqueue timestamp. |
| `job.scheduled_at` | Scheduled timestamp. |
| `job.status` | Summary status such as `ok` or `error`. |

## Messaging

| Key | Meaning |
| --- | --- |
| `messaging.system` | Messaging system, such as `kafka`. |
| `messaging.operation.name` | Operation name from the integration event. |
| `messaging.operation.type` | Generic type such as `process`, `receive`, or `send`. |
| `messaging.destination.name` | Topic, stream, or queue name. |
| `messaging.destination.partition.id` | Partition id. |
| `messaging.batch.message_count` | Message count in a batch. |
| `messaging.consumer.group.name` | Consumer group name. |
| `messaging.kafka.offset` | Kafka offset. |
| `messaging.kafka.message.key` | Kafka message key. |

Formatters should read neutral keys from `record.neutral` when producing
provider-native fields. They should not inspect integration-specific namespaces
unless they explicitly document that integration coupling.
