# `RecognitionGuidePrompt`

The recognition guide prompt, moved out of `AiService` (#431). `AiService#generate_recognition_guide` still makes the call and checks the reply.

## `.generate`

It takes the group's subject as a value, because a language-independent bucket's subject is its `LanguagePrompts::ALL` focus, which `AiService#recognition_subject` looks up. The group, its subject and its concepts are all it sees, so a guide cannot hint at any exercise.
