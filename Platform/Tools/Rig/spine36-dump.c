/*
 * Plays the schedules in a verify-pose.js plan through spine-c 3.6 (compiled
 * from its sources, as cocos2d-x 3.x shipped them) and writes each frame's
 * pose as JSON lines, in posedump's format. Each frame is cocos2d-x's
 * SkeletonAnimation::update: spAnimationState_update, _apply, then
 * spSkeleton_updateWorldTransform.
 *
 *   spine36dump <plan.json> <out dir> <skeleton dir>
 *
 * <skeleton dir> holds Rig<Name>.json in 3.6 format (spine36-convert.js).
 * Regions are given untrimmed, as the rigs' atlases pack them.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "spine/extension.h"
#include "spine/Json.h"
#include "spine/SkeletonJson.h"
#include "spine/Skeleton.h"
#include "spine/AnimationState.h"
#include "spine/RegionAttachment.h"
#include "spine/MeshAttachment.h"
#include "spine/ClippingAttachment.h"
#include "spine/PathAttachment.h"
#include "spine/BoundingBoxAttachment.h"
#include "spine/PointAttachment.h"

/* The cocos hooks spine-c expects. */
void _spAtlasPage_createTexture (spAtlasPage* self, const char* path) { (void)self; (void)path; }
void _spAtlasPage_disposeTexture (spAtlasPage* self) { (void)self; }
char* _spUtil_readFile (const char* path, int* length) { return _spReadFile(path, length); }

static spAttachment* createAttachment (spAttachmentLoader* loader, spSkin* skin, spAttachmentType type, const char* name, const char* path) {
	(void)loader; (void)skin; (void)path;
	switch (type) {
	case SP_ATTACHMENT_REGION: {
		spRegionAttachment* attachment = spRegionAttachment_create(name);
		attachment->regionWidth = attachment->regionOriginalWidth = 1;
		attachment->regionHeight = attachment->regionOriginalHeight = 1;
		return SUPER(attachment);
	}
	case SP_ATTACHMENT_MESH:
	case SP_ATTACHMENT_LINKED_MESH: {
		spMeshAttachment* attachment = spMeshAttachment_create(name);
		attachment->regionU2 = attachment->regionV2 = 1;
		attachment->regionWidth = attachment->regionOriginalWidth = 1;
		attachment->regionHeight = attachment->regionOriginalHeight = 1;
		return SUPER(SUPER(attachment));
	}
	case SP_ATTACHMENT_BOUNDING_BOX: return SUPER(SUPER(spBoundingBoxAttachment_create(name)));
	case SP_ATTACHMENT_PATH: return SUPER(SUPER(spPathAttachment_create(name)));
	case SP_ATTACHMENT_POINT: return SUPER(SUPER(spPointAttachment_create(name)));
	case SP_ATTACHMENT_CLIPPING: return SUPER(SUPER(spClippingAttachment_create(name)));
	default: return 0;
	}
}

static FILE* out;
static int frame;
static char events[1 << 20];

static void listener (spAnimationState* state, spEventType type, spTrackEntry* entry, spEvent* event) {
	const char* kind = 0;
	(void)state; (void)event;
	switch (type) {
	case SP_ANIMATION_START: kind = "start"; break;
	case SP_ANIMATION_INTERRUPT: kind = "interrupt"; break;
	case SP_ANIMATION_END: kind = "end"; break;
	case SP_ANIMATION_COMPLETE: kind = "complete"; break;
	default: return;
	}
	size_t used = strlen(events);
	snprintf(events + used, sizeof(events) - used, "%s\"%s %d %s @%d\"", used ? "," : "", kind, entry->trackIndex, entry->animation->name, frame);
}

static void number (float value, int first) {
	if (!first) fputc(',', out);
	if (value == 0 || value != value) fputc('0', out);
	else fprintf(out, "%.7g", value);
}

int main (int argc, char** argv) {
	int length;
	char* text;
	Json* plan;
	Json* run;
	float* buffer = MALLOC(float, 65536);
	if (argc < 4) {
		fprintf(stderr, "usage: spine36dump <plan.json> <out dir> <skeleton dir>\n");
		return 2;
	}
	text = _spReadFile(argv[1], &length);
	plan = Json_create(text);
	for (run = Json_getItem(plan, "runs")->child; run; run = run->next) {
		const char* id = Json_getString(run, "id", "");
		const char* rig = Json_getString(run, "rig", "");
		float scale = Json_getFloat(run, "scale", 1), dt = Json_getFloat(run, "dt", 1 / 60.0f);
		int frames = Json_getInt(run, "frames", 0), vertexEvery = Json_getInt(run, "vertexEvery", 10);
		char path[2048];
		spAttachmentLoader* loader = NEW(spAttachmentLoader);
		spSkeletonJson* json;
		spSkeletonData* data;
		spSkeleton* skeleton;
		spAnimationState* state;
		int i, ii;

		_spAttachmentLoader_init(loader, _spAttachmentLoader_deinit, createAttachment, 0, 0);
		json = spSkeletonJson_createWithLoader(loader);
		json->scale = scale;
		snprintf(path, sizeof(path), "%s/Rig%s.json", argv[3], rig);
		data = spSkeletonJson_readSkeletonDataFile(json, path);
		if (!data) {
			fprintf(stderr, "%s: %s\n", path, json->error);
			return 1;
		}
		skeleton = spSkeleton_create(data);
		spSkeleton_updateWorldTransform(skeleton);
		state = spAnimationState_create(spAnimationStateData_create(data));
		state->listener = listener;
		events[0] = 0;

		snprintf(path, sizeof(path), "%s/%s.jsonl", argv[2], id);
		out = fopen(path, "w");
		fprintf(out, "{\"bones\":[");
		for (i = 0; i < skeleton->bonesCount; i++) fprintf(out, "%s\"%s\"", i ? "," : "", skeleton->bones[i]->data->name);
		fprintf(out, "],\"slots\":[");
		for (i = 0; i < skeleton->slotsCount; i++) fprintf(out, "%s\"%s\"", i ? "," : "", skeleton->slots[i]->data->name);
		fprintf(out, "]}\n");

		for (frame = 0; frame < frames; frame++) {
			Json* action;
			for (action = Json_getItem(run, "actions")->child; action; action = action->next) {
				int track = Json_getInt(action, "track", 0), loop = Json_getInt(action, "loop", 0);
				const char* name = Json_getString(action, "name", "");
				if (Json_getInt(action, "frame", -1) != frame) continue;
				if (strcmp(Json_getString(action, "op", ""), "add") == 0)
					spAnimationState_addAnimationByName(state, track, name, loop, Json_getFloat(action, "delay", 0));
				else
					spAnimationState_setAnimationByName(state, track, name, loop);
			}
			spAnimationState_update(state, dt);
			spAnimationState_apply(state, skeleton);
			spSkeleton_updateWorldTransform(skeleton);

			fprintf(out, "{\"f\":%d,\"b\":[", frame);
			for (i = 0; i < skeleton->bonesCount; i++) {
				spBone* b = skeleton->bones[i];
				number(b->a, i == 0); number(b->b, 0); number(b->c, 0); number(b->d, 0); number(b->worldX, 0); number(b->worldY, 0);
			}
			fprintf(out, "],\"a\":[");
			for (i = 0; i < skeleton->slotsCount; i++) {
				spAttachment* a = skeleton->slots[i]->attachment;
				if (a) fprintf(out, "%s\"%s\"", i ? "," : "", a->name);
				else fprintf(out, "%snull", i ? "," : "");
			}
			fprintf(out, "],\"c\":[");
			for (i = 0; i < skeleton->slotsCount; i++) {
				spSlot* s = skeleton->slots[i];
				spColor t = {1, 1, 1, 1};
				if (s->attachment && s->attachment->type == SP_ATTACHMENT_REGION) t = ((spRegionAttachment*)s->attachment)->color;
				if (s->attachment && s->attachment->type == SP_ATTACHMENT_MESH) t = ((spMeshAttachment*)s->attachment)->color;
				number(skeleton->color.r * s->color.r * t.r, i == 0);
				number(skeleton->color.g * s->color.g * t.g, 0);
				number(skeleton->color.b * s->color.b * t.b, 0);
				number(skeleton->color.a * s->color.a * t.a, 0);
			}
			fprintf(out, "]");
			if (frame % vertexEvery == 0) {
				int first = 1;
				fprintf(out, ",\"v\":{");
				for (i = 0; i < skeleton->slotsCount; i++) {
					spSlot* s = skeleton->slots[i];
					spAttachment* a = s->attachment;
					int count;
					if (!a || a->type == SP_ATTACHMENT_BOUNDING_BOX || a->type == SP_ATTACHMENT_POINT) continue;
					if (a->type == SP_ATTACHMENT_REGION) {
						spRegionAttachment_computeWorldVertices((spRegionAttachment*)a, s->bone, buffer, 0, 2);
						count = 8;
					} else {
						spVertexAttachment* v = (spVertexAttachment*)a;
						count = v->worldVerticesLength;
						spVertexAttachment_computeWorldVertices(v, s, 0, count, buffer, 0, 2);
					}
					fprintf(out, "%s\"%d\":[", first ? "" : ",", i);
					first = 0;
					for (ii = 0; ii < count; ii++) number(buffer[ii], ii == 0);
					fprintf(out, "]");
				}
				fprintf(out, "}");
			}
			fprintf(out, "}\n");
		}
		fprintf(out, "{\"events\":[%s]}\n", events);
		fclose(out);
		spAnimationState_dispose(state);
		spSkeleton_dispose(skeleton);
	}
	return 0;
}
