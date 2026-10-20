# `RecognitionGuidePrompt`

The recognition guide prompt, moved out of `AiService` (#431). `AiService#generate_recognition_guide` still makes the call and checks the reply.

## `.generate`

It takes the group's subject as a value, because a language-independent bucket's subject is its `AiService::LANGUAGE_PROMPTS` focus, and a prompt class reads nothing from `AiService`. `AiService#recognition_subject` resolves it. The group, its subject and its concepts are all it sees, so a guide cannot hint at any exercise.
