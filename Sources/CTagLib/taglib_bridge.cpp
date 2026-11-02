// C bridge over TagLib 1.13 for SoundIsle.
//
// Design notes:
// - Tags are read/written through the concrete tag object of each format so
//   that album artist and artwork (absent from TagLib 1.13's generic Tag API)
//   work everywhere: ID3v2 (MP3/AIFF/WAV), MP4/M4A, Vorbis comments
//   (FLAC/Ogg), and APEv2.
// - Writes go to a temporary copy in the same directory which is atomically
//   renamed over the original, so a TagLib failure never corrupts the file.

#include "CTagLib.h"

#include <taglib/apefile.h>
#include <taglib/apeitem.h>
#include <taglib/apetag.h>
#include <taglib/attachedpictureframe.h>
#include <taglib/fileref.h>
#include <taglib/flacfile.h>
#include <taglib/flacpicture.h>
#include <taglib/id3v1tag.h>
#include <taglib/id3v2tag.h>
#include <taglib/mp4coverart.h>
#include <taglib/mp4file.h>
#include <taglib/mp4item.h>
#include <taglib/mp4tag.h>
#include <taglib/mpegfile.h>
#include <taglib/tag.h>
#include <taglib/tbytevector.h>
#include <taglib/textidentificationframe.h>
#include <taglib/tfile.h>
#include <taglib/tlist.h>
#include <taglib/tmap.h>
#include <taglib/tstring.h>
#include <taglib/tstringlist.h>
#include <taglib/wavfile.h>
#include <taglib/xiphcomment.h>

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <string>
#include <unistd.h>

namespace {

using TagLib::String;
using TagLib::StringList;

// MARK: - JSON

struct FieldValue {
    bool has = false;
    bool isNull = true;
    std::string text;
    long long number = 0;
};

using JsonObject = std::map<std::string, FieldValue>;

bool appendUTF8(std::string &out, unsigned int cp)
{
    if (cp <= 0x7F) {
        out += static_cast<char>(cp);
    } else if (cp <= 0x7FF) {
        out += static_cast<char>(0xC0 | (cp >> 6));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp <= 0xFFFF) {
        out += static_cast<char>(0xE0 | (cp >> 12));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp <= 0x10FFFF) {
        out += static_cast<char>(0xF0 | (cp >> 18));
        out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
        return false;
    }
    return true;
}

// Parses the flat JSON object produced by TagService.jsonData: string, integer
// and null values only. Unknown keys are kept but ignored by the applier.
class JsonParser
{
public:
    explicit JsonParser(const char *text) : m_text(text), m_pos(0) {}

    bool parseObject(JsonObject &out)
    {
        skipSpace();
        if (!consume('{')) {
            return false;
        }
        skipSpace();
        if (consume('}')) {
            return true;
        }
        while (true) {
            skipSpace();
            std::string key;
            if (!parseString(key)) {
                return false;
            }
            skipSpace();
            if (!consume(':')) {
                return false;
            }
            skipSpace();
            FieldValue value;
            if (!parseValue(value)) {
                return false;
            }
            out[key] = value;
            skipSpace();
            if (consume(',')) {
                continue;
            }
            return consume('}');
        }
    }

private:
    const char *m_text;
    std::size_t m_pos;

    void skipSpace()
    {
        while (m_text[m_pos] == ' ' || m_text[m_pos] == '\t'
               || m_text[m_pos] == '\n' || m_text[m_pos] == '\r') {
            ++m_pos;
        }
    }

    bool consume(char c)
    {
        if (m_text[m_pos] != c) {
            return false;
        }
        ++m_pos;
        return true;
    }

    bool parseValue(FieldValue &value)
    {
        if (m_text[m_pos] == '"') {
            value.has = true;
            value.isNull = false;
            return parseString(value.text);
        }
        if (std::strncmp(m_text + m_pos, "null", 4) == 0) {
            m_pos += 4;
            value.has = true;
            value.isNull = true;
            return true;
        }
        const char *start = m_text + m_pos;
        char *end = nullptr;
        long long number = std::strtoll(start, &end, 10);
        if (end == start) {
            return false;
        }
        m_pos += static_cast<std::size_t>(end - start);
        if (m_text[m_pos] == '.' || m_text[m_pos] == 'e' || m_text[m_pos] == 'E') {
            return false;
        }
        value.has = true;
        value.isNull = false;
        value.number = number;
        return true;
    }

    bool parseString(std::string &out)
    {
        if (!consume('"')) {
            return false;
        }
        while (m_text[m_pos] != '\0' && m_text[m_pos] != '"') {
            unsigned char c = static_cast<unsigned char>(m_text[m_pos++]);
            if (c != '\\') {
                out += static_cast<char>(c);
                continue;
            }
            char escape = m_text[m_pos++];
            switch (escape) {
            case '"': out += '"'; break;
            case '\\': out += '\\'; break;
            case '/': out += '/'; break;
            case 'b': out += '\b'; break;
            case 'f': out += '\f'; break;
            case 'n': out += '\n'; break;
            case 'r': out += '\r'; break;
            case 't': out += '\t'; break;
            case 'u': {
                unsigned int cp = 0;
                if (!parseHex4(cp)) {
                    return false;
                }
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    if (m_text[m_pos] != '\\' || m_text[m_pos + 1] != 'u') {
                        return false;
                    }
                    m_pos += 2;
                    unsigned int low = 0;
                    if (!parseHex4(low) || low < 0xDC00 || low > 0xDFFF) {
                        return false;
                    }
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                }
                if (!appendUTF8(out, cp)) {
                    return false;
                }
                break;
            }
            default:
                return false;
            }
        }
        return consume('"');
    }

    bool parseHex4(unsigned int &cp)
    {
        cp = 0;
        for (int i = 0; i < 4; ++i) {
            char c = m_text[m_pos++];
            cp <<= 4;
            if (c >= '0' && c <= '9') {
                cp |= static_cast<unsigned int>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                cp |= static_cast<unsigned int>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                cp |= static_cast<unsigned int>(c - 'A' + 10);
            } else {
                return false;
            }
        }
        return true;
    }
};

std::string jsonString(const String &value)
{
    if (value.isEmpty()) {
        return "null";
    }
    std::string out = "\"";
    const std::string utf8 = value.to8Bit(true);
    for (unsigned char c : utf8) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buffer[8];
                std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                out += buffer;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    out += '"';
    return out;
}

String stringValue(const FieldValue &value)
{
    return String(value.text, String::UTF8);
}

bool unsignedValue(const FieldValue &value, unsigned int &out)
{
    if (value.number < 0 || value.number > 0xFFFFFFFFLL) {
        return false;
    }
    out = static_cast<unsigned int>(value.number);
    return true;
}

const FieldValue *field(const JsonObject &object, const char *key)
{
    const auto it = object.find(key);
    if (it == object.end() || !it->second.has || it->second.isNull) {
        return nullptr;
    }
    return &it->second;
}

// MARK: - Base64

std::string base64Encode(const TagLib::ByteVector &data)
{
    static const char table[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned int size = data.size();
    std::string out;
    out.reserve(((size + 2) / 3) * 4);
    unsigned int i = 0;
    while (i + 2 < size) {
        const unsigned int v = (static_cast<unsigned char>(data[i]) << 16)
            | (static_cast<unsigned char>(data[i + 1]) << 8)
            | static_cast<unsigned char>(data[i + 2]);
        out += table[(v >> 18) & 0x3F];
        out += table[(v >> 12) & 0x3F];
        out += table[(v >> 6) & 0x3F];
        out += table[v & 0x3F];
        i += 3;
    }
    if (i < size) {
        const bool two = (i + 1 < size);
        unsigned int v = static_cast<unsigned char>(data[i]) << 16;
        if (two) {
            v |= static_cast<unsigned char>(data[i + 1]) << 8;
        }
        out += table[(v >> 18) & 0x3F];
        out += table[(v >> 12) & 0x3F];
        out += two ? table[(v >> 6) & 0x3F] : '=';
        out += '=';
    }
    return out;
}

bool base64Decode(const std::string &text, std::string &out)
{
    out.clear();
    unsigned int buffer = 0;
    int bits = 0;
    for (char ch : text) {
        if (ch == '=') {
            break;
        }
        if (ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t') {
            continue;
        }
        int value;
        if (ch >= 'A' && ch <= 'Z') {
            value = ch - 'A';
        } else if (ch >= 'a' && ch <= 'z') {
            value = ch - 'a' + 26;
        } else if (ch >= '0' && ch <= '9') {
            value = ch - '0' + 52;
        } else if (ch == '+') {
            value = 62;
        } else if (ch == '/') {
            value = 63;
        } else {
            return false;
        }
        buffer = (buffer << 6) | static_cast<unsigned int>(value);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out += static_cast<char>((buffer >> bits) & 0xFF);
        }
    }
    return true;
}

// MARK: - Raw tag selection

// Returns the tag that should be read for a file, preferring the tag type that
// carries album artist and artwork. Falls back to the generic view.
TagLib::Tag *readableTag(TagLib::File *file)
{
    if (!file) {
        return nullptr;
    }
    if (auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
        if (mpeg->hasID3v2Tag()) {
            return mpeg->ID3v2Tag();
        }
        if (mpeg->hasAPETag()) {
            return mpeg->APETag();
        }
        return mpeg->ID3v1Tag();
    }
    if (auto *flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        if (flac->hasXiphComment()) {
            return flac->xiphComment();
        }
        if (flac->hasID3v2Tag()) {
            return flac->ID3v2Tag();
        }
        return nullptr;
    }
    if (auto *ape = dynamic_cast<TagLib::APE::File *>(file)) {
        return ape->APETag();
    }
    if (auto *wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        return wav->ID3v2Tag();
    }
    return file->tag();
}

// Saves via the format's best API. MPEG gets DoNotDuplicate so a pre-existing
// ID3v1 tag is not copied into the ID3v2 tag we just edited (that would
// silently change fields the caller left nil).
bool saveFile(TagLib::File *file)
{
    if (auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
        return mpeg->save(TagLib::MPEG::File::AllTags, TagLib::File::StripNone,
                          TagLib::ID3v2::v4, TagLib::File::DoNotDuplicate);
    }
    return file->save();
}

// Returns a tag that can be written, creating one when the format allows it.
TagLib::Tag *writableTag(TagLib::File *file)
{
    if (!file) {
        return nullptr;
    }
    if (auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
        return mpeg->ID3v2Tag(true);
    }
    if (auto *flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        return flac->xiphComment(true);
    }
    if (auto *ape = dynamic_cast<TagLib::APE::File *>(file)) {
        return ape->APETag(true);
    }
    if (auto *wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        // TagLib 1.13 cannot create an ID3v2 chunk in a WAV file that lacks one.
        return wav->ID3v2Tag();
    }
    return file->tag();
}

// MARK: - Album artist

String albumArtistOf(TagLib::Tag *tag)
{
    if (!tag) {
        return String();
    }
    if (auto *id3 = dynamic_cast<TagLib::ID3v2::Tag *>(tag)) {
        const auto frames = id3->frameListMap().value("TPE2");
        if (!frames.isEmpty()) {
            return frames.front()->toString();
        }
    } else if (auto *mp4 = dynamic_cast<TagLib::MP4::Tag *>(tag)) {
        const auto values = mp4->item("aART").toStringList();
        if (!values.isEmpty()) {
            return values.front();
        }
    } else if (auto *xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(tag)) {
        auto values = xiph->fieldListMap().value("ALBUMARTIST");
        if (values.isEmpty()) {
            values = xiph->fieldListMap().value("ALBUM ARTIST");
        }
        if (!values.isEmpty()) {
            return values.front();
        }
    } else if (auto *ape = dynamic_cast<TagLib::APE::Tag *>(tag)) {
        for (auto it = ape->itemListMap().begin(); it != ape->itemListMap().end(); ++it) {
            const String key = it->first.upper();
            if (key == "ALBUMARTIST" || key == "ALBUM ARTIST") {
                return it->second.toString();
            }
        }
    }
    return String();
}

void setAlbumArtist(TagLib::Tag *tag, const String &value)
{
    if (auto *id3 = dynamic_cast<TagLib::ID3v2::Tag *>(tag)) {
        id3->removeFrames("TPE2");
        if (!value.isEmpty()) {
            auto *frame = new TagLib::ID3v2::TextIdentificationFrame("TPE2", String::UTF8);
            frame->setText(value);
            id3->addFrame(frame);
        }
    } else if (auto *mp4 = dynamic_cast<TagLib::MP4::Tag *>(tag)) {
        if (value.isEmpty()) {
            mp4->removeItem("aART");
        } else {
            StringList values;
            values.append(value);
            mp4->setItem("aART", TagLib::MP4::Item(values));
        }
    } else if (auto *xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(tag)) {
        xiph->removeFields("ALBUMARTIST");
        if (!value.isEmpty()) {
            xiph->addField("ALBUMARTIST", value);
        }
    } else if (auto *ape = dynamic_cast<TagLib::APE::Tag *>(tag)) {
        if (value.isEmpty()) {
            ape->removeItem("Album Artist");
        } else {
            ape->addValue("Album Artist", value, true);
        }
    }
}

// MARK: - Artwork

String mimeTypeOf(const TagLib::ByteVector &data)
{
    const char *bytes = data.data();
    const unsigned int size = data.size();
    if (size >= 8 && std::memcmp(bytes, "\x89PNG\r\n\x1a\n", 8) == 0) {
        return "image/png";
    }
    if (size >= 3 && static_cast<unsigned char>(bytes[0]) == 0xFF
        && static_cast<unsigned char>(bytes[1]) == 0xD8) {
        return "image/jpeg";
    }
    if (size >= 6 && std::memcmp(bytes, "GIF8", 4) == 0) {
        return "image/gif";
    }
    if (size >= 12 && std::memcmp(bytes, "RIFF", 4) == 0
        && std::memcmp(bytes + 8, "WEBP", 4) == 0) {
        return "image/webp";
    }
    if (size >= 2 && std::memcmp(bytes, "BM", 2) == 0) {
        return "image/bmp";
    }
    return "image/jpeg";
}

bool pictureOf(TagLib::Tag *tag, TagLib::ByteVector &data)
{
    if (!tag) {
        return false;
    }
    if (auto *id3 = dynamic_cast<TagLib::ID3v2::Tag *>(tag)) {
        const auto frames = id3->frameListMap().value("APIC");
        for (auto it = frames.begin(); it != frames.end(); ++it) {
            if (auto *picture = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(*it)) {
                if (!picture->picture().isEmpty()) {
                    data = picture->picture();
                    return true;
                }
            }
        }
    } else if (auto *xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(tag)) {
        const auto pictures = xiph->pictureList();
        for (auto it = pictures.begin(); it != pictures.end(); ++it) {
            if (!(*it)->data().isEmpty()) {
                data = (*it)->data();
                return true;
            }
        }
    } else if (auto *mp4 = dynamic_cast<TagLib::MP4::Tag *>(tag)) {
        const auto covers = mp4->item("covr").toCoverArtList();
        if (!covers.isEmpty() && !covers.front().data().isEmpty()) {
            data = covers.front().data();
            return true;
        }
    } else if (auto *ape = dynamic_cast<TagLib::APE::Tag *>(tag)) {
        for (auto it = ape->itemListMap().begin(); it != ape->itemListMap().end(); ++it) {
            if (it->first.upper().startsWith("COVER ART")) {
                const TagLib::ByteVector blob = it->second.binaryData();
                if (blob.isEmpty()) {
                    continue;
                }
                // APE cover art is "filename\0<image bytes>".
                const char *found = static_cast<const char *>(
                    std::memchr(blob.data(), '\0', blob.size()));
                const unsigned int offset = found
                    ? static_cast<unsigned int>(found - blob.data()) + 1
                    : 0;
                if (offset < blob.size()) {
                    data = blob.mid(offset);
                    return true;
                }
            }
        }
    }
    return false;
}

void setPicture(TagLib::Tag *tag, const TagLib::ByteVector &data)
{
    const String mime = mimeTypeOf(data);
    if (auto *id3 = dynamic_cast<TagLib::ID3v2::Tag *>(tag)) {
        id3->removeFrames("APIC");
        auto *frame = new TagLib::ID3v2::AttachedPictureFrame;
        frame->setMimeType(mime);
        frame->setType(TagLib::ID3v2::AttachedPictureFrame::FrontCover);
        frame->setDescription(String());
        frame->setPicture(data);
        id3->addFrame(frame);
    } else if (auto *xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(tag)) {
        xiph->removeAllPictures();
        auto *picture = new TagLib::FLAC::Picture;
        picture->setMimeType(mime);
        picture->setType(TagLib::FLAC::Picture::FrontCover);
        picture->setData(data);
        xiph->addPicture(picture);
    } else if (auto *mp4 = dynamic_cast<TagLib::MP4::Tag *>(tag)) {
        TagLib::MP4::CoverArt::Format format = TagLib::MP4::CoverArt::JPEG;
        if (mime == "image/png") {
            format = TagLib::MP4::CoverArt::PNG;
        } else if (mime == "image/gif") {
            format = TagLib::MP4::CoverArt::GIF;
        } else if (mime == "image/bmp") {
            format = TagLib::MP4::CoverArt::BMP;
        }
        TagLib::MP4::CoverArtList covers;
        covers.append(TagLib::MP4::CoverArt(format, data));
        mp4->setItem("covr", TagLib::MP4::Item(covers));
    } else if (auto *ape = dynamic_cast<TagLib::APE::Tag *>(tag)) {
        TagLib::ByteVector blob;
        blob.append('\0');
        blob.append(data);
        ape->setItem("Cover Art (Front)",
                     TagLib::APE::Item("Cover Art (Front)", blob, true));
    }
}

// MARK: - Read / write

std::string readJSON(TagLib::Tag *tag)
{
    TagLib::ByteVector artwork;
    const bool hasArtwork = pictureOf(tag, artwork);
    const unsigned int year = tag ? tag->year() : 0;
    const unsigned int track = tag ? tag->track() : 0;

    std::string json = "{";
    json += "\"title\":" + jsonString(tag ? tag->title() : String());
    json += ",\"artist\":" + jsonString(tag ? tag->artist() : String());
    json += ",\"album\":" + jsonString(tag ? tag->album() : String());
    json += ",\"albumArtist\":" + jsonString(albumArtistOf(tag));
    json += ",\"year\":" + (year > 0 ? std::to_string(year) : std::string("null"));
    json += ",\"trackNumber\":" + (track > 0 ? std::to_string(track) : std::string("null"));
    json += ",\"genre\":" + jsonString(tag ? tag->genre() : String());
    json += ",\"artworkBase64\":";
    json += hasArtwork ? "\"" + base64Encode(artwork) + "\"" : "null";
    json += "}";
    return json;
}

void applyFields(TagLib::Tag *tag, const JsonObject &object)
{
    if (auto *value = field(object, "title")) {
        tag->setTitle(stringValue(*value));
    }
    if (auto *value = field(object, "artist")) {
        tag->setArtist(stringValue(*value));
    }
    if (auto *value = field(object, "album")) {
        tag->setAlbum(stringValue(*value));
    }
    if (auto *value = field(object, "genre")) {
        tag->setGenre(stringValue(*value));
    }
    if (auto *value = field(object, "year")) {
        unsigned int year = 0;
        if (unsignedValue(*value, year)) {
            tag->setYear(year);
        }
    }
    if (auto *value = field(object, "trackNumber")) {
        unsigned int track = 0;
        if (unsignedValue(*value, track)) {
            tag->setTrack(track);
        }
    }
    if (auto *value = field(object, "albumArtist")) {
        setAlbumArtist(tag, stringValue(*value));
    }
    if (auto *value = field(object, "artworkBase64")) {
        std::string bytes;
        if (base64Decode(value->text, bytes) && !bytes.empty()) {
            setPicture(tag, TagLib::ByteVector(bytes.data(), static_cast<unsigned int>(bytes.size())));
        }
    }
}

bool hasWritableField(const JsonObject &object)
{
    static const char *keys[] = {
        "title", "artist", "album", "genre", "year",
        "trackNumber", "albumArtist", "artworkBase64"
    };
    for (const char *key : keys) {
        if (field(object, key)) {
            return true;
        }
    }
    return false;
}

void setError(char **error, const std::string &message)
{
    if (error) {
        *error = ::strdup(message.c_str());
    }
}

} // namespace

char *soundisle_read_tags(const char *path)
{
    if (!path) {
        return nullptr;
    }
    TagLib::FileRef ref{TagLib::FileName(path)};
    if (ref.isNull() || !ref.file()) {
        return nullptr;
    }
    TagLib::Tag *tag = readableTag(ref.file());
    if (!tag) {
        tag = ref.tag();
    }
    return ::strdup(readJSON(tag).c_str());
}

int soundisle_write_tags(const char *path, const char *json, char **error)
{
    if (error) {
        *error = nullptr;
    }
    if (!path) {
        setError(error, "无效的文件路径");
        return -1;
    }

    JsonObject fields;
    if (json) {
        JsonParser parser(json);
        if (!parser.parseObject(fields)) {
            setError(error, "标签数据格式无效");
            return -1;
        }
    }
    if (!hasWritableField(fields)) {
        return 0;
    }

    std::error_code ec;
    const std::string original(path);
    if (!std::filesystem::exists(original, ec)) {
        setError(error, "文件不存在");
        return -1;
    }

    // TagLib writes in place; write to a sibling copy and swap it in on success.
    const std::string temporary = original + ".soundisle-"
        + std::to_string(::getpid()) + "-" + std::to_string(::arc4random()) + ".tmp";
    std::filesystem::copy_file(original, temporary,
                               std::filesystem::copy_options::overwrite_existing, ec);
    if (ec) {
        setError(error, "无法创建临时文件: " + ec.message());
        return -1;
    }

    bool saved = false;
    std::string message = "写入标签失败";
    try {
        TagLib::FileRef ref{TagLib::FileName(temporary.c_str())};
        if (ref.isNull() || !ref.file()) {
            message = "不支持的音频格式";
        } else if (TagLib::Tag *tag = writableTag(ref.file())) {
            applyFields(tag, fields);
            if (saveFile(ref.file())) {
                saved = true;
            } else {
                message = "保存标签失败";
            }
        } else {
            message = "该格式无法写入标签";
        }
    } catch (...) {
        message = "写入标签时发生未知错误";
    }

    if (!saved) {
        std::filesystem::remove(temporary, ec);
        setError(error, message);
        return -1;
    }

    std::filesystem::rename(temporary, original, ec);
    if (ec) {
        std::filesystem::remove(temporary, ec);
        setError(error, "无法替换原文件: " + ec.message());
        return -1;
    }
    return 0;
}

void soundisle_free(char *ptr)
{
    std::free(ptr);
}
