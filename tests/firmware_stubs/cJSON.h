#pragma once
typedef struct cJSON { struct cJSON *next, *child; int type; char* valuestring; int valueint; double valuedouble; } cJSON;
cJSON* cJSON_Parse(const char*); void cJSON_Delete(cJSON*);
cJSON* cJSON_GetObjectItem(const cJSON*, const char*);
int cJSON_IsString(const cJSON*); int cJSON_IsNumber(const cJSON*); int cJSON_IsTrue(const cJSON*); int cJSON_IsArray(const cJSON*);
#define cJSON_ArrayForEach(element, array) for (element = (array != NULL) ? (array)->child : NULL; element != NULL; element = element->next)
